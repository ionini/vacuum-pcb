import Foundation

/// What kind of feature is on the other side of a thin-wall offence. Drives
/// the issue summary text and the picked colour palette in the sidebar.
enum ThinWallNeighbor: String, Hashable {
    /// Distance from a channel to the outer rectangle of the board.
    case outerFace
    /// Distance from a channel to another channel on the same plate
    /// (different net OR same net on a different layer). Same-layer
    /// different-net pairs are normally caught by `channelClearance`;
    /// this kind picks up cross-layer pairs where the 3D wall is thin.
    case channel
    /// Distance from a channel to a vertical bore on the same plate — a
    /// via or a transistor / LED drop bore.
    case bore
}

/// What a screw's clearance bore is too close to. A screw is a full-height
/// mechanical bore (head countersink + through-hole + nut pocket), so it
/// conflicts with fluid features on *either* plate — the checks are
/// plate-agnostic, unlike the per-plate channel checks.
enum ScrewNeighbor: String, Hashable {
    /// A routed channel segment (on any layer).
    case route
    /// A via / cross-plate bore.
    case via
    /// A transistor or LED drop / gate bore (a "pad").
    case pad
}

/// What an edge-port outlet (`portBoreClearance`) collides with on its way
/// from the port out to the board edge. The outlet exists only in the 3D /
/// mold geometry, so neither side of the clash is drawn on the 2D physical
/// layer — which is exactly why it slips past the routed-channel checks.
enum PortBoreNeighbor: String, Hashable {
    /// A foreign net's routed channel on the same plate-layer.
    case channel
    /// Another port's edge outlet on the same plate-layer.
    case outlet
}

/// Topology checks on the physical projection.
///
/// The schematic owns the netlist; the physical layout is a projection that
/// must realise it. Per-net we check that pins are joined by routed segments
/// (union-find on waypoints, same logic the CAD pipeline relies on), and we
/// cross-check pairs of route segments on each layer to make sure the printed
/// wall between foreign nets stays at least `manufacturing.minWallThickness`.
///
/// What we *don't* check yet (deferred to a fuller iter-4 DRC):
/// - routes crossing foreign component exclusion zones
/// - pin/route layer mismatches
/// - net membership of route segments (we accept the document's `Route.netId`
///   without re-verifying that the segments only touch that net's pins —
///   the routing UI is supposed to enforce that at draw time).
/// - resistor serpentines and port bores in the clearance check (route
///   segments only for now).
enum DRC {
    /// Transient "you clicked this issue, here's where it lives on the
    /// canvas" marker, animated as a fading pulse by the canvas overlay.
    /// `id` changes per click so SwiftUI re-mounts the overlay and restarts
    /// its animation even when the user re-clicks the same issue.
    struct Focus: Hashable {
        let id: UUID
        let position: Point
        let layer: Layer
    }

    struct Issue: Identifiable, Hashable {
        let id = UUID()
        let netId: UUID
        let netLabel: String
        let kind: Kind

        enum Kind: Hashable {
            /// The component that owns this pin has no placement, so we can't
            /// even tell where the pin sits to verify it. Place the component
            /// in the parking lot → board to clear this.
            case unplacedPin(PinRef)
            /// The net has at least two placed pins but no routes attached to
            /// its netId — nothing has been drawn yet.
            case noRouteDrawn
            /// The pin is placed but the routed segment graph does not reach
            /// it from the rest of the net's pins. Either the user hasn't
            /// finished routing or a segment endpoint isn't quite on the pin.
            case disconnectedPin(PinRef)
            /// A via waypoint exists at this XY but has no matching via
            /// waypoint on the *opposite* layer's segment of the same net —
            /// the cross-plate bore is one-sided and won't connect through
            /// the silicone. `segmentIndex` is the index of the segment
            /// inside the issue's net that carries this orphan via, so the
            /// sidebar can select it on click.
            case orphanVia(position: Point, segmentIndex: Int)
            /// Two route segments belonging to different nets leave a printed
            /// wall thinner than `manufacturing.minWallThickness` between them
            /// on the same plate. `wall` is that edge-to-edge thickness (centre
            /// distance minus both channel radii), clamped at 0.
            /// `selfSegmentIndex` is into the issue's net; the other pair
            /// (`otherNetId`, `otherSegmentIndex`) identifies the foreign
            /// segment so we can highlight both on click.
            case channelClearance(
                otherNetId: UUID,
                otherNetLabel: String,
                layer: Layer,
                wall: Double,
                selfSegmentIndex: Int,
                otherSegmentIndex: Int
            )
            /// Two electrically distinct nets are CSG-merged in the printed
            /// plate — channel centerlines pass within `channelDiameter`
            /// (the bores' tubes overlap) or a via on one net punches
            /// through the other's channel at the same XY. Detected on the
            /// flattened doc, so sub-part-internal routes participate too
            /// (which is what the user-visible `channelClearance` check
            /// misses). `otherNetLabel` is prefixed with the sub-part
            /// instance chain for routes hoisted out of a sub-part.
            case crossNetMerge(
                otherNetId: UUID,
                otherNetLabel: String,
                layer: Layer,
                position: Point
            )
            /// A channel segment sits close enough to some nearby feature
            /// that the printed wall between them falls below
            /// `minWallThickness` — the print will likely break through or
            /// fail under fluid pressure. `neighbor` distinguishes which
            /// kind of feature is on the other side; `segmentIndex` points
            /// at the offending channel segment within this issue's net so
            /// the sidebar can select it on click.
            case thinWall(
                neighbor: ThinWallNeighbor,
                layer: Layer,
                gap: Double,
                segmentIndex: Int,
                position: Point
            )
            /// A `Mating` references two connectors that don't compose
            /// (roles aren't opposite, pin counts differ, or an endpoint
            /// can't be resolved against the current document). Reason
            /// string is user-facing.
            case matingIncompatible(reason: String)
            /// A connector instance appears in more than one `Mating`.
            /// V1 allows each connector to be mated at most once.
            case matingDoubleBooked
            /// A screw's clearance bore sits close enough to a routed channel,
            /// a via, or a transistor/LED pad that the printed wall between
            /// them falls below `minWallThickness` — the fastener would break
            /// into the fluid path. `screwId` is the offending screw placement
            /// (for canvas selection); `position` is the screw centre.
            case screwClearance(
                screwId: UUID,
                neighbor: ScrewNeighbor,
                gap: Double,
                position: Point
            )
            /// Two vias on **different** nets sit close enough that the printed
            /// wall between their bores falls below `minWallThickness` (they'd
            /// merge into one void). `otherNetId` is the other via's net.
            case viaSpacing(
                otherNetId: UUID,
                otherNetLabel: String,
                layer: Layer,
                gap: Double,
                position: Point
            )
            /// A via sits close enough to a **foreign** transistor/LED pad bore
            /// that the printed wall falls below `minWallThickness`.
            /// `padComponentId` identifies the part whose pad is encroached.
            case viaPad(
                padComponentId: UUID,
                layer: Layer,
                gap: Double,
                position: Point
            )
            /// A hole in the silicone cutting *stencil* (a via hole, enlarged
            /// by `stencilViaPadding`) sits close enough to another sheet hole
            /// or the board edge that the remaining sheet wall is below
            /// `minWallThickness` — the thin cutting template would tear there.
            /// Stencil-only: the printed plate's bores are unaffected.
            case stencilHole(position: Point, gap: Double, detail: String)
            /// An edge-port **outlet** — the bore a port/vacuum/vent drills from
            /// its placement straight out to the board edge, generated only in
            /// the 3D / mold geometry — passes within `minWallThickness` of a
            /// foreign net's channel or another port's outlet on the same
            /// plate-layer. The 2D physical layer never draws the outlet, so the
            /// clash is invisible there and slips past `channelClearance`.
            /// `portComponentId` is the offending port (for canvas selection);
            /// `neighbor` says what it hit; `otherComponentId` is the other port
            /// when `neighbor == .outlet` (nil for a channel). `otherLabel` is
            /// the foreign net's label for a channel, or the other port's label
            /// for an outlet. `wall` is the edge-to-edge thickness clamped at 0;
            /// `position` drops the focus ping near the crossing.
            case portBoreClearance(
                portComponentId: UUID,
                portLabel: String,
                neighbor: PortBoreNeighbor,
                otherComponentId: UUID?,
                otherNetId: UUID,
                otherLabel: String,
                layer: Layer,
                wall: Double,
                position: Point
            )
        }

        var summary: String {
            switch kind {
            case .unplacedPin(let p):
                return "\(netLabel): pin \(p.pinKey) is on an unplaced component"
            case .noRouteDrawn:
                return "\(netLabel): no route drawn"
            case .disconnectedPin(let p):
                return "\(netLabel): pin \(p.pinKey) unreached by routing"
            case .orphanVia(let p, _):
                return "\(netLabel): unpaired via at (\(String(format: "%.1f", p.x)), \(String(format: "%.1f", p.y)))"
            case .channelClearance(_, let other, let layer, let wall, _, _):
                let where_ = layer.uiLabel
                let wallTxt = wall < 0.01 ? "touching" : "\(String(format: "%.2f", wall)) mm wall"
                return "\(netLabel) ↔ \(other) on \(where_): \(wallTxt)"
            case .crossNetMerge(_, let other, let layer, let p):
                return "\(netLabel) ↔ \(other) merge on \(layer.uiLabel)"
                    + " near (\(String(format: "%.1f", p.x)), \(String(format: "%.1f", p.y)))"
            case let .thinWall(neighbor, layer, gap, _, _):
                let kindTxt: String
                switch neighbor {
                case .outerFace: kindTxt = "outer face"
                case .channel:   kindTxt = "another channel"
                case .bore:      kindTxt = "a bore"
                }
                let gapTxt = gap < 0.01
                    ? "wall < 0.01 mm"
                    : "\(String(format: "%.2f", gap)) mm wall"
                return "\(netLabel) on \(layer.uiLabel): thin wall to \(kindTxt) (\(gapTxt))"
            case .matingIncompatible(let reason):
                return "\(netLabel): \(reason)"
            case .matingDoubleBooked:
                return "\(netLabel): connector mated more than once"
            case let .screwClearance(_, neighbor, gap, _):
                let what: String
                switch neighbor {
                case .route: what = "a channel"
                case .via:   what = "a via"
                case .pad:   what = "a transistor pad"
                }
                let gapTxt = gap < 0.01 ? "wall < 0.01 mm" : "\(String(format: "%.2f", gap)) mm wall"
                return "\(netLabel): screw too close to \(what) (\(gapTxt))"
            case let .viaSpacing(_, other, layer, gap, _):
                let gapTxt = gap < 0.01 ? "touching" : "\(String(format: "%.2f", gap)) mm wall"
                return "\(netLabel) ↔ \(other) vias on \(layer.uiLabel): \(gapTxt)"
            case let .viaPad(_, layer, gap, _):
                let gapTxt = gap < 0.01 ? "touching" : "\(String(format: "%.2f", gap)) mm wall"
                return "\(netLabel) via near a transistor pad on \(layer.uiLabel): \(gapTxt)"
            case let .stencilHole(_, gap, detail):
                let gapTxt = gap < 0.01 ? "holes touch/overlap" : "\(String(format: "%.2f", gap)) mm sheet wall"
                return "Stencil sheet: \(detail) (\(gapTxt))"
            case let .portBoreClearance(_, portLabel, neighbor, _, _, otherLabel, layer, wall, _):
                let what = neighbor == .channel ? "channel \(otherLabel)" : "\(otherLabel) outlet"
                let wallTxt = wall < 0.01 ? "touching" : "\(String(format: "%.2f", wall)) mm wall"
                return "\(portLabel) outlet → \(what) on \(layer.uiLabel): \(wallTxt)"
            }
        }
    }

    /// Maps an issue to a physical-canvas selection that highlights the
    /// offending elements. Returns `nil` if the issue can't be visualised
    /// on the physical view (e.g. an unplaced pin).
    static func physicalSelection(for issue: Issue, in document: CircuitDocument) -> PhysicalSelection? {
        switch issue.kind {
        case .unplacedPin:
            return nil
        case .noRouteDrawn:
            guard let net = document.logic.nets.first(where: { $0.id == issue.netId }) else { return nil }
            var sel = PhysicalSelection()
            sel.placements = Set(net.pins.map(\.componentId))
            return sel.isEmpty ? nil : sel
        case .disconnectedPin(let pinRef):
            return .placement(pinRef.componentId)
        case .orphanVia(_, let segIdx):
            return .routeSegment(netId: issue.netId, segmentIndex: segIdx)
        case let .channelClearance(otherNetId, _, _, _, selfSeg, otherSeg):
            // Highlight the self-segment as the focused route, and the
            // foreign segment via its waypoints so both halves of the
            // collision are visible at once. The placements set is left
            // empty so the user's attention stays on the routes.
            var sel = PhysicalSelection.routeSegment(netId: issue.netId, segmentIndex: selfSeg)
            if let otherRoute = document.physical.routes.first(where: { $0.netId == otherNetId }),
               otherSeg < otherRoute.segments.count {
                let segment = otherRoute.segments[otherSeg]
                for wIdx in 0..<segment.waypoints.count {
                    sel.waypoints.insert(RouteWaypointAddress(
                        netId: otherNetId, segmentIndex: otherSeg, waypointIndex: wIdx
                    ))
                }
            }
            return sel
        case let .thinWall(_, _, _, segIdx, _):
            return .routeSegment(netId: issue.netId, segmentIndex: segIdx)
        case .matingIncompatible, .matingDoubleBooked:
            // Mating issues live in the schematic — there's no physical
            // canvas affordance to highlight (the physical tab is gated
            // off in assembly mode anyway).
            return nil
        case .crossNetMerge(let otherNetId, let otherLabel, _, _):
            // For each side of the merge, highlight whatever the user can
            // act on in the unflattened canvas:
            //   * net at the parent level → all its pins (placements set)
            //   * net hoisted out of a sub-part → that instance's placement,
            //     identified by the label prefix ("U1.n3" → component
            //     labelled "U1"). Lets the user jump into the sub-part view
            //     where the actual offending segment lives.
            let parentNets = Set(document.logic.nets.map(\.id))
            var sel = PhysicalSelection()
            func selectSide(netId: UUID, label: String) {
                if parentNets.contains(netId),
                   let net = document.logic.nets.first(where: { $0.id == netId }) {
                    sel.placements.formUnion(net.pins.map(\.componentId))
                    return
                }
                if let dot = label.firstIndex(of: "."),
                   let instance = document.logic.components.first(where: {
                       $0.kind == .subpart && $0.label == String(label[..<dot])
                   }) {
                    sel.placements.insert(instance.id)
                }
            }
            selectSide(netId: issue.netId, label: issue.netLabel)
            selectSide(netId: otherNetId, label: otherLabel)
            return sel.isEmpty ? nil : sel
        case .screwClearance(let screwId, _, _, _):
            return .placement(screwId)
        case .viaPad(let padComponentId, _, _, _):
            return .placement(padComponentId)
        case .stencilHole:
            // A sheet-geometry issue with no single owning placement; the
            // focus ping (below) lands the user near the crowded spot.
            return nil
        case .viaSpacing:
            // Both ends are vias mid-route; the net pins are the actionable
            // handle (drag a part to open the gap).
            guard let net = document.logic.nets.first(where: { $0.id == issue.netId }) else { return nil }
            var sel = PhysicalSelection()
            sel.placements = Set(net.pins.map(\.componentId))
            return sel.isEmpty ? nil : sel
        case let .portBoreClearance(portComponentId, _, neighbor, otherComponentId, otherNetId, _, _, _, _):
            // The port is the handle to drag/rotate so its outlet steers clear.
            // Add the other side too: the paired port for an outlet↔outlet
            // clash, or the foreign net's pins for a channel.
            var sel = PhysicalSelection()
            sel.placements.insert(portComponentId)
            if neighbor == .outlet, let other = otherComponentId {
                sel.placements.insert(other)
            } else if let net = document.logic.nets.first(where: { $0.id == otherNetId }) {
                sel.placements.formUnion(net.pins.map(\.componentId))
            }
            return sel.isEmpty ? nil : sel
        }
    }

    /// Position to drop a transient focus marker on when the user clicks an
    /// issue in the sidebar. Returns nil for issues that don't have a clear
    /// single point (unplaced pin / no-route nets exist in logical state, not
    /// on the canvas). The companion overlay only renders when the layer is
    /// currently visible — issues on a hidden layer still select the right
    /// placements, just without the ping.
    static func focusPosition(for issue: Issue, in document: CircuitDocument) -> (Point, Layer)? {
        switch issue.kind {
        case .crossNetMerge(_, _, let layer, let pos):
            return (pos, layer)
        case let .orphanVia(pos, segIdx):
            guard let route = document.physical.routes.first(where: { $0.netId == issue.netId }),
                  segIdx < route.segments.count
            else { return nil }
            return (pos, route.segments[segIdx].layer)
        case let .channelClearance(_, _, layer, _, selfSeg, _):
            guard let route = document.physical.routes.first(where: { $0.netId == issue.netId }),
                  selfSeg < route.segments.count
            else { return nil }
            let pts = route.segments[selfSeg].waypoints.map(\.position)
            guard !pts.isEmpty else { return nil }
            return (pts[pts.count / 2], layer)
        case .disconnectedPin(let ref):
            guard let placement = document.physical.placements.first(where: { $0.componentId == ref.componentId }),
                  let comp = document.logic.components.first(where: { $0.id == ref.componentId }),
                  let pin = comp.footprint(document.manufacturing, snapshots: document.librarySnapshots).pin(ref.pinKey)
            else { return nil }
            return (placement.worldPosition(of: pin), placement.resolvedLayer(of: pin, on: comp))
        case let .thinWall(_, layer, _, _, pos):
            return (pos, layer)
        case let .viaSpacing(_, _, layer, _, pos):
            return (pos, layer)
        case let .viaPad(_, layer, _, pos):
            return (pos, layer)
        case let .stencilHole(pos, _, _):
            // The sheet sits in the silicone gap; ping on the top depth-0
            // layer so the marker lands at the crowded XY.
            return (pos, Layer(plate: .top, depth: 0))
        case let .screwClearance(_, _, _, pos):
            // A screw spans both plates; ping on the top depth-0 layer.
            return (pos, Layer(plate: .top, depth: 0))
        case let .portBoreClearance(_, _, _, _, _, _, layer, _, pos):
            return (pos, layer)
        case .unplacedPin, .noRouteDrawn, .matingIncompatible, .matingDoubleBooked:
            return nil
        }
    }

    static func check(_ document: CircuitDocument) -> [Issue] {
        var issues: [Issue] = []
        for net in document.logic.nets {
            issues.append(contentsOf: checkNet(net, in: document))
        }
        issues.append(contentsOf: clearanceIssues(in: document))
        issues.append(contentsOf: crossNetMergeIssues(in: document))
        issues.append(contentsOf: thinWallIssues(in: document))
        issues.append(contentsOf: matingIssues(in: document))
        issues.append(contentsOf: screwClearanceIssues(in: document))
        issues.append(contentsOf: viaClearanceIssues(in: document))
        issues.append(contentsOf: stencilHoleIssues(in: document))
        issues.append(contentsOf: portBoreClearanceIssues(in: document))
        return issues
    }

    // MARK: - Stencil cutting-sheet crowding

    /// Flags places where the silicone cutting *stencil* would tear: a via
    /// through-hole (enlarged by `stencilViaPadding`) sits within
    /// `minWallThickness` of another through-hole in the sheet (another via, a
    /// screw clearance bore, a connector pin) or a transistor / LED dimple
    /// (where the silicone has to flex). Stencil-only — the printed plate bores
    /// are unaffected by the padding, so this never duplicates the plate
    /// checks. Runs on the *flattened* design because the stencil itself is
    /// built flattened (it punches sub-part vias too), so a top-level-only pass
    /// would miss almost every hole.
    private static func stencilHoleIssues(in doc: CircuitDocument) -> [Issue] {
        let flat = doc.flattened()
        let m = flat.manufacturing
        guard m.stencilThickness > 0, m.minWallThickness > 0 else { return [] }
        let threshold = m.minWallThickness

        struct Hole { let pos: Point; let radius: Double; let label: String }
        // The padded via through-holes are the only holes the padding changes —
        // the check is centred on them.
        let viaRadius = (m.channelDiameter + m.stencilViaPadding) / 2
        let vias = flat.physical.crossSiliconeViaPositions().map {
            Hole(pos: $0, radius: viaRadius, label: "via")
        }
        guard !vias.isEmpty else { return [] }

        // Neighbours that share the silicone sheet: other through-holes (screw
        // shafts, bottom-extend connector pins) and the transistor / LED
        // dimples the silicone deflects into.
        let comps = Dictionary(flat.logic.components.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var others: [Hole] = []
        for pl in flat.physical.placements {
            guard let c = comps[pl.componentId] else { continue }
            switch c.kind {
            case .screw:
                others.append(Hole(pos: pl.position, radius: ScrewGeometry.throughDiameter / 2,
                                   label: "screw"))
            case .connector where (c.connectorRole ?? .bottomExtend) == .bottomExtend:
                for pin in c.footprint(m, snapshots: flat.librarySnapshots).pins {
                    others.append(Hole(pos: pl.worldPosition(of: pin), radius: m.channelDiameter / 2,
                                       label: "connector pin"))
                }
            case .transistor:
                others.append(Hole(pos: pl.position, radius: m.dimpleDiameter / 2, label: "transistor dimple"))
            case .led:
                others.append(Hole(pos: pl.position, radius: m.ledDimpleDiameter / 2, label: "LED dimple"))
            default:
                break
            }
        }

        func dist(_ a: Point, _ b: Point) -> Double {
            ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
        }
        var issues: [Issue] = []
        func emit(_ pos: Point, _ gap: Double, _ detail: String) {
            issues.append(Issue(netId: UUID(), netLabel: "Stencil",
                                kind: .stencilHole(position: pos, gap: max(0, gap), detail: detail)))
        }

        for i in 0..<vias.count {
            for j in (i + 1)..<vias.count {
                let wall = dist(vias[i].pos, vias[j].pos) - vias[i].radius - vias[j].radius
                if wall < threshold { emit(midpoint(vias[i].pos, vias[j].pos), wall, "two via holes") }
            }
            for o in others {
                let wall = dist(vias[i].pos, o.pos) - vias[i].radius - o.radius
                if wall < threshold { emit(midpoint(vias[i].pos, o.pos), wall, "via hole ↔ \(o.label)") }
            }
        }
        return issues
    }

    // MARK: - Screw clearance

    /// A printed bore description used by the screw / via clearance checks:
    /// a vertical hole of `radius` at `position`, attributed to a net (and,
    /// for transistor/LED pads, the owning component).
    private struct Bore {
        let position: Point
        let radius: Double
        let layer: Layer
        /// Net this bore belongs to. Same-net pairs are allowed to come
        /// arbitrarily close — they're going to fuse in CSG anyway, which is
        /// the whole point of routing. `nil` if the bore can't be attributed
        /// to a net.
        let netId: UUID?
        let componentId: UUID?
        /// World-Z extent of the bore — the band of plate height it actually
        /// occupies. A cross-silicone via spans the silicone face to the
        /// midlines it connects on this plate; an intra-plate via (T0↔T1 /
        /// B0↔B1) only spans between its own layer midlines; a pin drop bore
        /// spans the face to its channel midline; a transistor gate / LED
        /// dome reaches its cavity depth past the face. The screw check
        /// measures the vertical gap to its stepped columns against this
        /// band; `viaClearanceIssues` and `thinWallIssues` use it to skip
        /// features that don't share plate height.
        let zLo: Double
        let zHi: Double
    }

    /// Collects every via bore and every transistor / LED pad bore in the
    /// document, on their resolved layers, tagged with the net (and component)
    /// they belong to so the clearance checks can skip same-net pairs that are
    /// meant to fuse. Via waypoints are grouped by (net, XY) to learn the full
    /// layer set each via spans, then emitted as one bore per plate with the
    /// Z band it occupies there — so an intra-plate via doesn't pretend to
    /// reach the silicone face.
    private static func collectBores(in doc: CircuitDocument) -> [Bore] {
        let m = doc.manufacturing
        let channelRadius = m.channelDiameter / 2
        func faceZ(_ plate: Plate) -> Double {
            plate == .top ? m.siliconeThickness / 2 : -m.siliconeThickness / 2
        }
        var pinToNet: [PinRef: UUID] = [:]
        for net in doc.logic.nets {
            for pinRef in net.pins { pinToNet[pinRef] = net.id }
        }
        var bores: [Bore] = []

        struct ViaGroup { var position: Point; var layers: Set<Layer>; var netId: UUID }
        var viaGroups: [ViaGroup] = []
        for route in doc.physical.routes {
            for segment in route.segments {
                for wp in segment.waypoints where wp.kind == .via {
                    if let i = viaGroups.firstIndex(where: {
                        $0.netId == route.netId
                            && abs($0.position.x - wp.position.x) < 0.05
                            && abs($0.position.y - wp.position.y) < 0.05
                    }) {
                        viaGroups[i].layers.insert(segment.layer)
                    } else {
                        viaGroups.append(ViaGroup(
                            position: wp.position, layers: [segment.layer], netId: route.netId
                        ))
                    }
                }
            }
        }
        for group in viaGroups {
            let plates = Set(group.layers.map(\.plate))
            let crossesSilicone = plates.count >= 2
            for plate in plates {
                let plateLayers = group.layers.filter { $0.plate == plate }
                var zs = plateLayers.map { m.midZ(for: $0) }
                if crossesSilicone { zs.append(faceZ(plate)) }
                // Attribute the bore to the plate's innermost layer; only the
                // plate half matters to the checks, the depth is in [zLo, zHi].
                let layer = plateLayers.min { $0.depth < $1.depth }!
                bores.append(Bore(position: group.position, radius: channelRadius,
                                  layer: layer, netId: group.netId, componentId: nil,
                                  zLo: zs.min()!, zHi: zs.max()!))
            }
        }
        for placement in doc.physical.placements {
            guard let comp = doc.logic.components.first(where: { $0.id == placement.componentId })
            else { continue }
            switch comp.kind {
            case .transistor, .led:
                let fp = comp.footprint(m, snapshots: doc.librarySnapshots)
                for pin in fp.pins {
                    let ref = PinRef(componentId: placement.componentId, pinKey: pin.key)
                    let pinLayer = placement.resolvedLayer(of: pin, on: comp)
                    let face = faceZ(pinLayer.plate)
                    // Drop bore runs from the silicone face to its channel
                    // midline; a transistor gate / LED indicator carves a dome
                    // reaching `cavityDepth` past the face. Matches the reach
                    // used by `thinWallIssues`.
                    var reach = abs(m.midZ(for: pinLayer) - face)
                    if comp.kind == .transistor, pin.key == "gate" {
                        reach = max(reach, m.dimpleDiameter / 2 + m.dimpleSphereOffset)
                    } else if comp.kind == .led {
                        reach = max(reach, m.ledDimpleDiameter / 2 + m.ledDimpleDepth)
                    }
                    let zEnd = face + (pinLayer.plate == .top ? reach : -reach)
                    bores.append(Bore(
                        position: placement.worldPosition(of: pin),
                        radius: channelRadius,
                        layer: pinLayer,
                        netId: pinToNet[ref],
                        componentId: placement.componentId,
                        zLo: min(face, zEnd), zHi: max(face, zEnd)
                    ))
                }
            default:
                break
            }
        }
        return bores
    }

    /// Flags screws whose clearance bore would break into a nearby channel,
    /// via, or transistor/LED pad. A screw is a *stepped* bore, not a uniform
    /// column: the wide head countersink only carves the top `screwHeadDepth`
    /// of the head-side plate, the wide hex pocket only the top
    /// `screwNutDepth` of the opposite plate, and a narrow through-shaft
    /// connects them everywhere else (and across the silicone). So the wall
    /// to a feature is measured against whichever screw section actually
    /// shares the feature's height — the head only where a channel runs past
    /// the countersink, the shaft for buried channels and `screwProtrusion`-
    /// retracted heads. One issue per (screw, neighbor kind) so a screw in a
    /// crowded area reports at most three times.
    private static func screwClearanceIssues(in doc: CircuitDocument) -> [Issue] {
        let m = doc.manufacturing
        let threshold = m.minWallThickness
        guard threshold > 0 else { return [] }
        let channelRadius = m.channelDiameter / 2

        // Plate Z extents, matching the CAD pipeline (`PlateBuilder`), so the
        // screw's collision profile lands at the same heights it's printed at.
        let topInnerZ = m.siliconeThickness / 2
        let bottomInnerZ = -m.siliconeThickness / 2
        let topThickness = m.plateThickness(forLayerCount: doc.physical.topLayers)
        let bottomThickness = m.plateThickness(forLayerCount: doc.physical.bottomLayers)

        // `placement.layer` (a `Plate`) is the head side; the nut sinks into
        // the opposite plate — same convention the CAD pipeline uses.
        let screws: [(id: UUID, label: String, p: Point, headSide: Plate)] = doc.physical.placements.compactMap { pl in
            guard let comp = doc.logic.components.first(where: { $0.id == pl.componentId }),
                  comp.kind == .screw else { return nil }
            return (comp.id, comp.label.isEmpty ? "Screw" : comp.label, pl.position, pl.layer)
        }
        guard !screws.isEmpty else { return [] }

        let edges = collectRouteEdges(in: doc)
        let bores = collectBores(in: doc)

        struct ReportKey: Hashable { let screwId: UUID; let neighbor: ScrewNeighbor }
        var reported: Set<ReportKey> = []
        var issues: [Issue] = []
        func emit(_ screw: (id: UUID, label: String, p: Point, headSide: Plate),
                  _ neighbor: ScrewNeighbor, _ gap: Double) {
            let key = ReportKey(screwId: screw.id, neighbor: neighbor)
            if reported.contains(key) { return }
            reported.insert(key)
            issues.append(Issue(
                netId: UUID(), netLabel: screw.label,
                kind: .screwClearance(screwId: screw.id, neighbor: neighbor,
                                      gap: max(0, gap), position: screw.p)
            ))
        }

        // Thinnest printed wall between a screw's profile and a feature on
        // `plate` that occupies `[fLo, fHi]` in Z, `dxy` away laterally. Each
        // screw section adds the vertical gap to its band before deducting
        // radii, so a section the feature doesn't reach in Z can't bind; the
        // narrow shaft (spanning the whole plate) sets the floor.
        func minWall(_ columns: [ScrewGeometry.ClearanceColumn], plate: Plate,
                     dxy: Double, fLo: Double, fHi: Double, featureRadius: Double) -> Double {
            var best = Double.greatestFiniteMagnitude
            for col in columns where col.plate == plate {
                let dz = max(0, max(col.zLo - fHi, fLo - col.zHi))
                let centre = (dxy * dxy + dz * dz).squareRoot()
                best = min(best, centre - col.radius - featureRadius)
            }
            return best
        }

        for screw in screws {
            let columns = ScrewGeometry.clearanceColumns(
                topInnerZ: topInnerZ, topThickness: topThickness,
                bottomInnerZ: bottomInnerZ, bottomThickness: bottomThickness,
                protrusion: m.screwProtrusion, headDepth: m.screwHeadDepth,
                nutDepth: m.screwNutDepth, headSide: screw.headSide
            )
            for edge in edges {
                let dxy = pointSegmentDistance(screw.p, edge.a, edge.b)
                let cz = m.midZ(for: edge.layer)
                let wall = minWall(columns, plate: edge.layer.plate,
                                   dxy: dxy, fLo: cz, fHi: cz, featureRadius: channelRadius)
                if wall < threshold { emit(screw, .route, wall) }
            }
            for bore in bores {
                let dx = screw.p.x - bore.position.x, dy = screw.p.y - bore.position.y
                let dxy = (dx * dx + dy * dy).squareRoot()
                let wall = minWall(columns, plate: bore.layer.plate,
                                   dxy: dxy, fLo: bore.zLo, fHi: bore.zHi, featureRadius: bore.radius)
                if wall < threshold { emit(screw, bore.componentId == nil ? .via : .pad, wall) }
            }
        }
        return issues
    }

    // MARK: - Via clearance (via↔via, via↔pad)

    /// Flags via bores that sit too close to a *foreign-net* via or transistor
    /// pad on the same plate — the printed walls between the two bores fall
    /// below `minWallThickness` and would merge into one void. The existing
    /// `thinWall(.bore)` check only measures *channel edges* against bores;
    /// this adds the bore-against-bore cases it misses. Same-net pairs are
    /// skipped (they're meant to fuse).
    ///
    /// Depth-aware: a pair only conflicts when the two bores' Z bands
    /// genuinely overlap — a T0↔T1 via passes safely beside a shallow
    /// depth-0 drop bore. Bands that merely *touch* at a shared channel
    /// midline don't count either: each bore opens into that depth's channel
    /// there, and the walls around the channels are `thinWall` /
    /// `channelClearance`'s job.
    private static func viaClearanceIssues(in doc: CircuitDocument) -> [Issue] {
        let m = doc.manufacturing
        let threshold = m.minWallThickness
        guard threshold > 0 else { return [] }
        let labels = Dictionary(uniqueKeysWithValues: doc.logic.nets.map { ($0.id, $0.label) })

        let bores = collectBores(in: doc)
        let vias = bores.filter { $0.componentId == nil }   // route vias only
        guard !vias.isEmpty else { return [] }

        func dist(_ a: Point, _ b: Point) -> Double {
            ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
        }
        func zOverlaps(_ a: Bore, _ b: Bore) -> Bool {
            min(a.zHi, b.zHi) - max(a.zLo, b.zLo) > 1e-9
        }

        struct PairKey: Hashable {
            let a: UUID; let b: UUID; let plate: Plate
            init(_ x: UUID, _ y: UUID, _ plate: Plate) {
                let ord = x.uuidString < y.uuidString ? (x, y) : (y, x)
                self.a = ord.0; self.b = ord.1; self.plate = plate
            }
        }
        var reported: Set<PairKey> = []
        var issues: [Issue] = []

        // via ↔ via (different nets, same plate, sharing plate height)
        for i in 0..<vias.count {
            for j in (i + 1)..<vias.count {
                let a = vias[i], b = vias[j]
                guard a.layer.plate == b.layer.plate else { continue }
                guard let an = a.netId, let bn = b.netId, an != bn else { continue }
                guard zOverlaps(a, b) else { continue }
                let wall = dist(a.position, b.position) - a.radius - b.radius
                guard wall < threshold else { continue }
                let key = PairKey(an, bn, a.layer.plate)
                if reported.contains(key) { continue }
                reported.insert(key)
                issues.append(Issue(
                    netId: an, netLabel: labels[an] ?? "?",
                    kind: .viaSpacing(otherNetId: bn, otherNetLabel: labels[bn] ?? "?",
                                      layer: a.layer, gap: max(0, wall),
                                      position: midpoint(a.position, b.position))
                ))
            }
        }

        // via ↔ foreign transistor/LED pad (same plate, sharing plate height)
        let pads = bores.filter { $0.componentId != nil }
        struct VPKey: Hashable { let net: UUID; let comp: UUID; let plate: Plate }
        var reportedVP: Set<VPKey> = []
        for via in vias {
            guard let vn = via.netId else { continue }
            for pad in pads where pad.layer.plate == via.layer.plate {
                if pad.netId == vn { continue }   // same net: meant to connect
                guard zOverlaps(via, pad) else { continue }
                let wall = dist(via.position, pad.position) - via.radius - pad.radius
                guard wall < threshold else { continue }
                let key = VPKey(net: vn, comp: pad.componentId!, plate: via.layer.plate)
                if reportedVP.contains(key) { continue }
                reportedVP.insert(key)
                issues.append(Issue(
                    netId: vn, netLabel: labels[vn] ?? "?",
                    kind: .viaPad(padComponentId: pad.componentId!, layer: via.layer,
                                  gap: max(0, wall), position: via.position)
                ))
            }
        }
        return issues
    }

    private static func midpoint(_ a: Point, _ b: Point) -> Point {
        Point(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    /// Resolves a `ConnectorEndpoint` against the parent document, returning
    /// the underlying connector `Component` plus the user-facing label to
    /// quote in issue text. Top-level endpoints resolve directly; subpart
    /// sockets resolve through the placement's library snapshot.
    private static func resolveEndpoint(
        _ endpoint: ConnectorEndpoint,
        in document: CircuitDocument
    ) -> (component: Component, label: String)? {
        switch endpoint {
        case .topLevel(let id):
            guard let comp = document.logic.components.first(where: { $0.id == id }),
                  comp.kind == .connector
            else { return nil }
            return (comp, comp.label)
        case .subpartSocket(let subpartId, let connectorId):
            guard let subpart = document.logic.components.first(where: { $0.id == subpartId }),
                  subpart.kind == .subpart,
                  let part = subpart.resolvedPart(snapshots: document.librarySnapshots),
                  let comp = part.document.logic.components.first(where: { $0.id == connectorId }),
                  comp.kind == .connector
            else { return nil }
            return (comp, "\(subpart.label).\(comp.label)")
        }
    }

    private static func matingIssues(in document: CircuitDocument) -> [Issue] {
        var issues: [Issue] = []
        // Track each connector's appearance count so we can flag a
        // double-mating exactly once per offending endpoint. The endpoint
        // value type is Hashable thanks to the enum + UUID associated
        // values, so it doubles as the dict key.
        var endpointSeen: [ConnectorEndpoint: Int] = [:]
        for mating in document.logic.matings {
            endpointSeen[mating.a, default: 0] += 1
            endpointSeen[mating.b, default: 0] += 1
        }
        for mating in document.logic.matings {
            let a = resolveEndpoint(mating.a, in: document)
            let b = resolveEndpoint(mating.b, in: document)
            let label = "Mating \(a?.label ?? "?")↔\(b?.label ?? "?")"
            guard let a, let b else {
                issues.append(Issue(
                    netId: mating.id, netLabel: label,
                    kind: .matingIncompatible(reason: "one or both connectors no longer exist")
                ))
                continue
            }
            if a.component.connectorRole == b.component.connectorRole {
                issues.append(Issue(
                    netId: mating.id, netLabel: label,
                    kind: .matingIncompatible(reason: "both halves have the same role; one must be bottom-extend and the other top-extend")
                ))
            }
            let aPins = a.component.connectorPinCount ?? 0
            let bPins = b.component.connectorPinCount ?? 0
            if aPins != bPins || aPins == 0 {
                issues.append(Issue(
                    netId: mating.id, netLabel: label,
                    kind: .matingIncompatible(reason: "pin counts don't match (\(aPins) vs \(bPins))")
                ))
            }
        }
        for (endpoint, count) in endpointSeen where count > 1 {
            let label = resolveEndpoint(endpoint, in: document)?.label ?? "?"
            issues.append(Issue(
                netId: UUID(), netLabel: "Connector \(label)",
                kind: .matingDoubleBooked
            ))
        }
        return issues
    }

    private static func checkNet(_ net: Net, in document: CircuitDocument) -> [Issue] {
        // A net with fewer than two pins is trivially "connected" (or doesn't
        // need a wire). It also gets pruned by the schematic editor anyway.
        guard net.pins.count >= 2 else { return [] }

        // Resolve pin world positions. Anything unplaced is a separate issue
        // (we can't reason about its connectivity yet) and disqualifies the
        // pin from the union-find pass.
        var pinPositions: [PinRef: Point] = [:]
        var pinLayers: [PinRef: Layer] = [:]
        var netPinsByLayer: [Layer: [Point]] = [:]
        var issues: [Issue] = []
        for pinRef in net.pins {
            guard let placement = document.physical.placements.first(where: { $0.componentId == pinRef.componentId }),
                  let component = document.logic.components.first(where: { $0.id == pinRef.componentId }),
                  let fpPin = component.footprint(document.manufacturing, snapshots: document.librarySnapshots).pin(pinRef.pinKey)
            else {
                issues.append(Issue(netId: net.id, netLabel: net.label, kind: .unplacedPin(pinRef)))
                continue
            }
            let world = placement.worldPosition(of: fpPin)
            pinPositions[pinRef] = world
            let layer = placement.resolvedLayer(of: fpPin, on: component)
            pinLayers[pinRef] = layer
            netPinsByLayer[layer, default: []].append(world)
        }
        guard pinPositions.count >= 2 else { return issues }

        let routes = document.physical.routes.filter { $0.netId == net.id }
        let segments = routes.flatMap(\.segments)
        guard !segments.isEmpty else {
            // Pins that all resolve to the same (layer, XY) fuse in CSG —
            // their drop bores are one void, physically connected with no
            // channel needed (the port-on-socket pattern). Ratsnest already
            // maps them to a single node at the same 0.05 mm tolerance, so
            // emitting `noRouteDrawn` here would be a false positive the
            // user can't route away.
            let eps = 0.05
            let allCoincident = pinPositions.allSatisfy { ref, p in
                guard let first = pinPositions.first else { return true }
                return pinLayers[ref] == pinLayers[first.key]
                    && abs(p.x - first.value.x) < eps
                    && abs(p.y - first.value.y) < eps
            }
            if !allCoincident {
                issues.append(Issue(netId: net.id, netLabel: net.label, kind: .noRouteDrawn))
            }
            return issues
        }

        // Map points to integer node ids using a tolerance so floating point
        // chatter on grid-snapped coords doesn't fragment the graph.
        var nodes: [Point] = []
        let epsilon = 0.05
        func nodeIndex(for p: Point) -> Int {
            for (i, q) in nodes.enumerated() {
                if abs(q.x - p.x) < epsilon && abs(q.y - p.y) < epsilon {
                    return i
                }
            }
            nodes.append(p)
            return nodes.count - 1
        }

        // Union-find on the waypoint graph: each segment unions its consecutive
        // waypoints into one component. Pins are inserted as their own nodes
        // beforehand so coincident positions resolve to the same node id.
        var parent: [Int] = []
        func ensure(_ i: Int) {
            while parent.count <= i { parent.append(parent.count) }
        }
        func find(_ x: Int) -> Int {
            ensure(x)
            var current = x
            while parent[current] != current {
                parent[current] = parent[parent[current]]
                current = parent[current]
            }
            return current
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        var pinNodes: [PinRef: Int] = [:]
        for (pinRef, pos) in pinPositions {
            pinNodes[pinRef] = nodeIndex(for: pos)
        }
        // Pin-snap tolerance: matches PlateBuilder.extendedWaypointPositions
        // so a route end that drifts away from its pin (because padsOffset
        // moved) still counts as connected here.
        let pinSnapTol = document.manufacturing.dimpleDiameter / 2 + 0.01
        for segment in segments {
            let positions = PlateBuilder.extendedWaypointPositions(
                for: segment,
                pinsOnLayer: netPinsByLayer[segment.layer] ?? [],
                tolerance: pinSnapTol
            )
            guard positions.count >= 2 else { continue }
            let indices = positions.map { nodeIndex(for: $0) }
            for i in 0..<(indices.count - 1) {
                union(indices[i], indices[i + 1])
            }
        }

        // All placed pins must share a root with the first placed pin.
        let roots = pinNodes.mapValues { find($0) }
        guard let referenceRoot = roots.values.first else { return issues }
        for (pinRef, root) in roots where root != referenceRoot {
            issues.append(Issue(netId: net.id, netLabel: net.label, kind: .disconnectedPin(pinRef)))
        }

        // Every via must appear at the *same* XY on at least one segment per
        // layer; otherwise the cross-plate bore is one-sided.
        issues.append(contentsOf: viaIssues(
            net: net, segments: segments,
            pinsByLayer: netPinsByLayer
        ))

        return issues
    }

    private static func viaIssues(
        net: Net, segments: [Segment], pinsByLayer: [Layer: [Point]]
    ) -> [Issue] {
        // Group via waypoints by approximate XY → which layers carry one,
        // and which segments hold them so the sidebar can select the
        // offending segment when the user clicks the issue.
        struct Group {
            var position: Point
            var layers: Set<Layer>
            var segmentIndices: [Int]
        }
        var groups: [Group] = []
        let eps = 0.05
        for (segIdx, segment) in segments.enumerated() {
            for wp in segment.waypoints where wp.kind == .via {
                if let i = groups.firstIndex(where: {
                    abs($0.position.x - wp.position.x) < eps && abs($0.position.y - wp.position.y) < eps
                }) {
                    groups[i].layers.insert(segment.layer)
                    groups[i].segmentIndices.append(segIdx)
                } else {
                    groups.append(Group(position: wp.position, layers: [segment.layer], segmentIndices: [segIdx]))
                }
            }
        }
        // A single-layer ("orphan") via is decorative ONLY when it lands on a
        // pin *of its own layer*: that pin's bore already anchors the channel
        // at that XY, and PlateBuilder skips the one-sided bore. A via that
        // lands on a pin of a DIFFERENT layer is still a real break — the route
        // on this layer never reaches the pin's layer without a paired via — so
        // it must report. (This is exactly the `4bit register with bus` case: a
        // B1 via sitting on the register's B0 input pin.) Matching on the via's
        // own layer keeps DRC consistent with the ratsnest, which treats a pin
        // as anchoring only its own layer. True mid-route orphans (no pin on
        // that layer) report as before.
        func coincidesWithPinOnLayer(_ p: Point, _ layer: Layer) -> Bool {
            (pinsByLayer[layer] ?? []).contains { abs($0.x - p.x) < eps && abs($0.y - p.y) < eps }
        }
        return groups
            .filter { $0.layers.count < 2 && !coincidesWithPinOnLayer($0.position, $0.layers.first!) }
            .map { Issue(
                netId: net.id, netLabel: net.label,
                kind: .orphanVia(position: $0.position, segmentIndex: $0.segmentIndices.first ?? 0)
            ) }
    }

    // MARK: - Channel clearance

    private struct ChannelEdge {
        let netId: UUID
        let netLabel: String
        let segmentIndex: Int
        let layer: Layer
        let a: Point
        let b: Point
    }

    /// Walks every pair of route polyline edges; if two edges on the same
    /// plate-layer belong to different nets and the printed wall between them
    /// — centre distance minus both channel radii — is thinner than
    /// `minWallThickness`, emit one issue per (net-pair, layer). We don't spam
    /// the sidebar with every offending segment; the user just needs to know
    /// "those two nets clash on top, look at the canvas".
    ///
    /// Diameter-aware on purpose: the reported number is the actual wall, not
    /// the centre-to-centre distance, so it lines up with `thinWall` (which
    /// defers the same-layer different-net case to here) instead of leaving a
    /// `channelDiameter`-thick blind spot. `minChannelSpacing` stays the
    /// auto-router's centre-to-centre keep-out — the *physical* limit is the
    /// wall, and that's what DRC enforces.
    private static func clearanceIssues(in doc: CircuitDocument) -> [Issue] {
        let threshold = doc.manufacturing.minWallThickness
        guard threshold > 0 else { return [] }
        let channelRadius = doc.manufacturing.channelDiameter / 2
        let edges = collectRouteEdges(in: doc)
        guard edges.count >= 2 else { return [] }

        struct PairKey: Hashable {
            let first: UUID, second: UUID, layer: Layer
            init(_ a: UUID, _ b: UUID, _ layer: Layer) {
                let ordered = a.uuidString < b.uuidString ? (a, b) : (b, a)
                self.first = ordered.0; self.second = ordered.1; self.layer = layer
            }
        }
        var reported: Set<PairKey> = []
        var issues: [Issue] = []
        for i in 0..<edges.count {
            for j in (i + 1)..<edges.count {
                let a = edges[i], b = edges[j]
                if a.netId == b.netId { continue }
                if a.layer != b.layer { continue }
                let key = PairKey(a.netId, b.netId, a.layer)
                if reported.contains(key) { continue }
                let d = segmentDistance(a.a, a.b, b.a, b.b)
                let wall = d - 2 * channelRadius
                guard wall < threshold else { continue }
                reported.insert(key)
                issues.append(Issue(
                    netId: a.netId, netLabel: a.netLabel,
                    kind: .channelClearance(
                        otherNetId: b.netId, otherNetLabel: b.netLabel,
                        layer: a.layer, wall: max(0, wall),
                        selfSegmentIndex: a.segmentIndex,
                        otherSegmentIndex: b.segmentIndex
                    )
                ))
            }
        }
        return issues
    }

    private static func collectRouteEdges(in doc: CircuitDocument) -> [ChannelEdge] {
        let labels = Dictionary(uniqueKeysWithValues: doc.logic.nets.map { ($0.id, $0.label) })
        var out: [ChannelEdge] = []
        for route in doc.physical.routes {
            let label = labels[route.netId] ?? "?"
            for (segIdx, seg) in route.segments.enumerated() {
                let pts = seg.waypoints
                guard pts.count >= 2 else { continue }
                for i in 0..<(pts.count - 1) {
                    out.append(ChannelEdge(
                        netId: route.netId, netLabel: label,
                        segmentIndex: segIdx, layer: seg.layer,
                        a: pts[i].position, b: pts[i + 1].position
                    ))
                }
            }
        }
        return out
    }

    /// 2D point-to-point on collapsed segments, point-to-segment otherwise,
    /// and an explicit intersection test so two crossing edges produce a 0
    /// gap (the four-endpoint distances alone would miss that).
    private static func segmentDistance(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> Double {
        if segmentsIntersect(a, b, c, d) { return 0 }
        return min(
            min(pointSegmentDistance(a, c, d), pointSegmentDistance(b, c, d)),
            min(pointSegmentDistance(c, a, b), pointSegmentDistance(d, a, b))
        )
    }

    private static func pointSegmentDistance(_ p: Point, _ a: Point, _ b: Point) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else {
            let ex = p.x - a.x, ey = p.y - a.y
            return (ex * ex + ey * ey).squareRoot()
        }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq))
        let projX = a.x + t * dx
        let projY = a.y + t * dy
        let ex = p.x - projX, ey = p.y - projY
        return (ex * ex + ey * ey).squareRoot()
    }

    private static func segmentsIntersect(_ p1: Point, _ p2: Point, _ p3: Point, _ p4: Point) -> Bool {
        func cross(_ a: Point, _ b: Point, _ c: Point) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        let d1 = cross(p3, p4, p1)
        let d2 = cross(p3, p4, p2)
        let d3 = cross(p1, p2, p3)
        let d4 = cross(p1, p2, p4)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0))
            && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }

    // MARK: - Port outlet clearance

    /// An edge-port outlet swept to the board edge — the same straight bore
    /// `PlateBuilder.portBoreMesh` drills, reduced to its 2D centreline plus a
    /// radius. We treat it as a constant-radius channel at the bore's *nominal*
    /// diameter (`portBoreDiameter`), exactly as routed channels are modelled
    /// at `channelDiameter` — i.e. we ignore the gentle 1° taper. The taper
    /// only widens the bore toward the open edge, and folding it in (a bounding
    /// cylinder at the wide-end radius) badly over-reports long sweeps: a 60 mm
    /// outlet would balloon to a ~4 mm-wide phantom and flag channels a couple
    /// of millimetres clear. Nominal keeps the check honest and consistent.
    private struct PortBore {
        let componentId: UUID
        let label: String
        let netId: UUID
        let netLabel: String
        let layer: Layer
        let a: Point          // route end (port placement)
        let b: Point          // board-edge exit
        let radius: Double
    }

    /// Builds the outlet centreline for every port / vacuum / vent placement,
    /// projecting straight to the board edge along the placement rotation — the
    /// same edge mapping `portBoreMesh` uses (r0→+X, r180→−X, r90→+Y, r270→−Y),
    /// minus the 0.5 mm overshoot (it lands outside the board, where it can't
    /// collide with anything inside).
    private static func collectPortBores(in doc: CircuitDocument) -> [PortBore] {
        let m = doc.manufacturing
        let outline = doc.physical.boardOutline
        let radius = m.portBoreDiameter / 2

        // A port-like part has a single pneumatic pin, so the net it belongs to
        // is whichever net references its component id.
        var netOf: [UUID: (id: UUID, label: String)] = [:]
        for net in doc.logic.nets {
            for pin in net.pins where netOf[pin.componentId] == nil {
                netOf[pin.componentId] = (net.id, net.label)
            }
        }
        let compById = Dictionary(
            doc.logic.components.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )

        var out: [PortBore] = []
        for placement in doc.physical.placements {
            guard let comp = compById[placement.componentId],
                  comp.kind == .port || comp.kind == .vacuumSource || comp.kind == .atmVent
            else { continue }
            let p = placement.position
            let b: Point
            let length: Double
            switch placement.rotation {
            case .r0:   b = Point(x: outline.maxX, y: p.y); length = outline.maxX - p.x
            case .r180: b = Point(x: outline.minX, y: p.y); length = p.x - outline.minX
            case .r90:  b = Point(x: p.x, y: outline.maxY); length = outline.maxY - p.y
            case .r270: b = Point(x: p.x, y: outline.minY); length = p.y - outline.minY
            }
            guard length > 0 else { continue }
            let net = netOf[placement.componentId]
            out.append(PortBore(
                componentId: placement.componentId,
                label: comp.label,
                netId: net?.id ?? placement.componentId,
                netLabel: net?.label ?? comp.label,
                layer: Layer(plate: placement.layer, depth: placement.depth),
                a: p, b: b,
                radius: radius
            ))
        }
        return out
    }

    /// Flags port outlets that collide on their run to the board edge — against
    /// a foreign net's routed channel (e.g. a vacuum tap sailing over a signal
    /// channel on the 2D layer) or against another port's outlet — on the same
    /// plate-layer, leaving a printed wall below `minWallThickness`. Same-net
    /// pairs are skipped: the port's own route attaches at the pin, and same-net
    /// outlets share fluid anyway. One issue per (offending port, other net,
    /// layer); the channel pass runs first so a clash that's both a channel and
    /// that net's outlet reports once, as the channel.
    private static func portBoreClearanceIssues(in doc: CircuitDocument) -> [Issue] {
        let threshold = doc.manufacturing.minWallThickness
        guard threshold > 0 else { return [] }
        let bores = collectPortBores(in: doc)
        guard !bores.isEmpty else { return [] }
        let channelRadius = doc.manufacturing.channelDiameter / 2
        let routeEdges = collectRouteEdges(in: doc)

        struct PairKey: Hashable { let port: UUID; let other: UUID; let layer: Layer }
        var reported: Set<PairKey> = []
        var issues: [Issue] = []

        // Outlet vs foreign routed channels.
        for bore in bores {
            for edge in routeEdges where edge.layer == bore.layer && edge.netId != bore.netId {
                let wall = segmentDistance(bore.a, bore.b, edge.a, edge.b) - (bore.radius + channelRadius)
                guard wall < threshold,
                      reported.insert(PairKey(port: bore.componentId, other: edge.netId, layer: bore.layer)).inserted
                else { continue }
                issues.append(Issue(
                    netId: bore.netId, netLabel: bore.netLabel,
                    kind: .portBoreClearance(
                        portComponentId: bore.componentId, portLabel: bore.label,
                        neighbor: .channel, otherComponentId: nil,
                        otherNetId: edge.netId, otherLabel: edge.netLabel,
                        layer: bore.layer, wall: max(0, wall),
                        position: approachPoint(bore.a, bore.b, edge.a, edge.b)
                    )
                ))
            }
        }

        // Outlet vs other outlets.
        for i in 0..<bores.count {
            for j in (i + 1)..<bores.count {
                let a = bores[i], b = bores[j]
                guard a.netId != b.netId, a.layer == b.layer else { continue }
                let wall = segmentDistance(a.a, a.b, b.a, b.b) - (a.radius + b.radius)
                guard wall < threshold,
                      reported.insert(PairKey(port: a.componentId, other: b.netId, layer: a.layer)).inserted
                else { continue }
                issues.append(Issue(
                    netId: a.netId, netLabel: a.netLabel,
                    kind: .portBoreClearance(
                        portComponentId: a.componentId, portLabel: a.label,
                        neighbor: .outlet, otherComponentId: b.componentId,
                        otherNetId: b.netId, otherLabel: b.label,
                        layer: a.layer, wall: max(0, wall),
                        position: approachPoint(a.a, a.b, b.a, b.b)
                    )
                ))
            }
        }
        return issues
    }

    // MARK: - Cross-net electrical merge

    /// Flags pairs of channel edges from different nets whose centerlines
    /// pass within `channelDiameter` on the same layer — at that distance the
    /// two cylindrical bores share volume in CSG and become one continuous
    /// void in the printed plate, electrically merging the nets. Runs on the
    /// flattened doc so sub-part-internal routes are visible (the user-side
    /// `clearanceIssues` walks the unflattened doc and misses them).
    ///
    /// Includes the via-vs-foreign-channel case implicitly: a `.via` waypoint
    /// at XY on layer L appears as a degenerate (length-0) edge at that XY,
    /// and `segmentDistance` reduces to point-to-segment for it.
    private static func crossNetMergeIssues(in doc: CircuitDocument) -> [Issue] {
        let (flat, labels) = doc.flattenedWithLabels()
        let threshold = flat.manufacturing.channelDiameter

        struct E {
            let netId: UUID
            let label: String
            let layer: Layer
            let a: Point
            let b: Point
        }
        var edges: [E] = []
        for route in flat.physical.routes {
            let label = labels[route.netId] ?? "?"
            for seg in route.segments {
                let pts = seg.waypoints.map(\.position)
                guard pts.count >= 2 else { continue }
                for i in 0..<(pts.count - 1) {
                    edges.append(E(
                        netId: route.netId, label: label, layer: seg.layer,
                        a: pts[i], b: pts[i + 1]
                    ))
                }
            }
        }

        struct PairKey: Hashable {
            let first: UUID, second: UUID, layer: Layer
            init(_ a: UUID, _ b: UUID, _ layer: Layer) {
                let ord = a.uuidString < b.uuidString ? (a, b) : (b, a)
                self.first = ord.0; self.second = ord.1; self.layer = layer
            }
        }
        var reported: Set<PairKey> = []
        var issues: [Issue] = []
        for i in 0..<edges.count {
            for j in (i + 1)..<edges.count {
                let a = edges[i], b = edges[j]
                if a.netId == b.netId { continue }
                if a.layer != b.layer { continue }
                let key = PairKey(a.netId, b.netId, a.layer)
                if reported.contains(key) { continue }
                let d = segmentDistance(a.a, a.b, b.a, b.b)
                guard d < threshold else { continue }
                reported.insert(key)
                issues.append(Issue(
                    netId: a.netId, netLabel: a.label,
                    kind: .crossNetMerge(
                        otherNetId: b.netId, otherNetLabel: b.label,
                        layer: a.layer,
                        position: approachPoint(a.a, a.b, b.a, b.b)
                    )
                ))
            }
        }

        // --- Channel ↔ transistor source/drain pad breach ---
        // A transistor switches by sealing the strip of plate between its
        // source and drain pads; the gate dome flexes the silicone over that
        // strip. A channel whose centerline crosses that strip drills a void
        // straight through it, permanently shorting source to drain — the
        // "hole between source and drain" failure.
        //
        // Detection works in the transistor's own frame: project each channel
        // edge onto the source→drain axis (origin at the gate). The breach
        // signature is the edge crossing the axis (endpoints on opposite
        // sides) at a point within the pads' half-height — i.e. passing
        // *between* the pads where there's wall to destroy. A channel that
        // merely terminates at one pad and runs outward stays on one side and
        // never crosses, so legitimate source/drain connections (and the
        // common same-net graze of a supply line skimming one pad) don't trip.
        //
        // The pad cavities live inside sub-parts, so this only surfaces on the
        // flattened doc: the un-flattened `clearanceIssues` / `thinWallIssues`
        // never see them, and the route-vs-route loop above doesn't model pads.
        let m = flat.manufacturing
        let comps = Dictionary(flat.logic.components.map { ($0.id, $0) },
                               uniquingKeysWith: { first, _ in first })
        // Half the pad cap's footprint along the axis perpendicular — the span
        // over which solid wall actually separates the two pads.
        let padHalfHeight = (pow(m.padsDiameter / 2, 2) - pow(m.padsSeparation / 2, 2)).squareRoot()
        var breachReported: Set<String> = []
        for placement in flat.physical.placements {
            guard let comp = comps[placement.componentId], comp.kind == .transistor
            else { continue }
            let fp = comp.footprint(m, snapshots: flat.librarySnapshots)
            // Pads sit on the plate opposite the gate dome, at the silicone
            // face (depth 0).
            let padLayer = Layer(plate: placement.layer.opposite, depth: 0)
            guard let aPin = fp.pin("a"), let bPin = fp.pin("b") else { continue }
            let gate = placement.position
            let source = placement.worldPosition(of: aPin)
            let drain = placement.worldPosition(of: bPin)
            let axisLen = (pow(drain.x - source.x, 2) + pow(drain.y - source.y, 2)).squareRoot()
            guard axisLen > 0 else { continue }
            let ux = (drain.x - source.x) / axisLen, uy = (drain.y - source.y) / axisLen
            func axisCoord(_ p: Point) -> Double { (p.x - gate.x) * ux + (p.y - gate.y) * uy }
            for e in edges where e.layer == padLayer {
                let sA = axisCoord(e.a), sB = axisCoord(e.b)
                // Edge must straddle the source→drain axis (opposite signs).
                guard (sA < 0) != (sB < 0), sA != sB else { continue }
                let t = sA / (sA - sB)
                let cross = Point(x: e.a.x + t * (e.b.x - e.a.x),
                                  y: e.a.y + t * (e.b.y - e.a.y))
                // Perpendicular distance from the gate to the crossing: the
                // along-axis component is 0 there, so it's just |cross − gate|.
                let perp = (pow(cross.x - gate.x, 2) + pow(cross.y - gate.y, 2)).squareRoot()
                guard perp < padHalfHeight else { continue }
                let key = "\(placement.componentId.uuidString)|\(e.netId.uuidString)"
                if breachReported.contains(key) { continue }
                breachReported.insert(key)
                issues.append(Issue(
                    netId: e.netId, netLabel: e.label,
                    kind: .crossNetMerge(
                        // `otherNetId` carries the transistor's id (not a net):
                        // it's only used for canvas focus, and `comp.label`
                        // ("U4.Q1") drives the sub-part-instance selection.
                        otherNetId: comp.id, otherNetLabel: comp.label,
                        layer: padLayer,
                        position: cross
                    )
                ))
            }
        }
        return issues
    }

    /// Midpoint of the two segments' midpoints. Good enough to drop a marker
    /// near the offending area — the user inspects the canvas for the exact
    /// crossing, and a closest-point solve would be heavier than the rest of
    /// this check combined.
    private static func approachPoint(
        _ a: Point, _ b: Point, _ c: Point, _ d: Point
    ) -> Point {
        let m1 = Point(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let m2 = Point(x: (c.x + d.x) / 2, y: (c.y + d.y) / 2)
        return Point(x: (m1.x + m2.x) / 2, y: (m1.y + m2.y) / 2)
    }

    // MARK: - Wall thickness

    /// Walks every channel polyline edge and flags places where the printed
    /// wall between the channel and a nearby feature (outer face, another
    /// channel, a vertical bore) is thinner than `minWallThickness`.
    /// Shares the wall-thickness model with `channelClearance` (which owns the
    /// same-layer different-net channel case) but covers what that one can't:
    /// the outer face, vertical bores, and cross-layer channel pairs whose 3D
    /// wall is thin. `crossNetMerge` is the orthogonal electrical check —
    /// centre distance under `channelDiameter`, i.e. the tubes actually overlap.
    ///
    /// Dedup is per `(netId, segmentIndex, neighbor)` so a long parallel
    /// run reports one issue per neighbor category rather than per edge.
    private static func thinWallIssues(in doc: CircuitDocument) -> [Issue] {
        let m = doc.manufacturing
        let threshold = m.minWallThickness
        guard threshold > 0 else { return [] }

        let labels = Dictionary(uniqueKeysWithValues: doc.logic.nets.map { ($0.id, $0.label) })
        let channelRadius = m.channelDiameter / 2
        let edges = collectRouteEdges(in: doc)
        guard !edges.isEmpty else { return [] }

        // True outer-polygon edges: the rectangular `boardOutline` with each
        // connector protrusion punched out on its anchor edge. Without this
        // step, routes that legitimately head into a connector pin (which
        // physically sits inside the protrusion, *outside* the rectangle)
        // would clip the bare-rect edge and trip a false thin-wall warning
        // at every connector.
        //
        // A design flagged as a reusable sub-component has no real outer face
        // (its outline is embedded inside a larger plate), so suppress the
        // board-edge wall check for it — an empty edge set turns the per-edge
        // loop below into a no-op without a second code path. The flag is read
        // off the top-level doc only; this never reaches a sub-part's internal
        // routes, so a parent re-checks its own edges with its own flag.
        let outlineEdges = (doc.skipEdgeWallDRC ?? false) ? [] : outerBoundaryEdges(in: doc)

        // Bores carry the world-Z band they occupy so the wall check can tell
        // a real same-depth conflict from a buried channel passing safely over
        // a shallow feature one layer away, and their net id so the check can
        // skip same-net pairs (a transistor's drop bore sitting near another
        // segment of its own net would otherwise produce a spurious thin-wall
        // warning — the two volumes are supposed to fuse, not stay separated).
        // Port / vent / vacuum-source bores enter horizontally and
        // intentionally meet the outer face — `collectBores` never emits
        // them, so they can't produce false positives at every port.
        let bores = collectBores(in: doc)

        struct ReportKey: Hashable {
            let netId: UUID
            let segmentIndex: Int
            let neighbor: ThinWallNeighbor
        }
        var reported: Set<ReportKey> = []
        var issues: [Issue] = []

        func emit(edge: ChannelEdge, neighbor: ThinWallNeighbor,
                  gap: Double, position: Point) {
            let key = ReportKey(
                netId: edge.netId,
                segmentIndex: edge.segmentIndex,
                neighbor: neighbor
            )
            if reported.contains(key) { return }
            reported.insert(key)
            let label = labels[edge.netId] ?? edge.netLabel
            issues.append(Issue(
                netId: edge.netId, netLabel: label,
                kind: .thinWall(
                    neighbor: neighbor,
                    layer: edge.layer,
                    gap: max(0, gap),
                    segmentIndex: edge.segmentIndex,
                    position: position
                )
            ))
        }

        for edge in edges {
            // --- Outer face ---
            // Bores meeting the outer face are valid for port-type pins, but
            // we skip those bores entirely above, so any channel-edge-to-
            // outline hit here is an actual thin wall.
            for outlineE in outlineEdges {
                let d = segmentDistance(edge.a, edge.b, outlineE.a, outlineE.b)
                let wall = d - channelRadius
                if wall < threshold {
                    // Report position: approachPoint reads "near here" with
                    // enough fidelity for the canvas ping.
                    let pos = approachPoint(edge.a, edge.b, outlineE.a, outlineE.b)
                    emit(edge: edge, neighbor: .outerFace, gap: wall, position: pos)
                }
            }

            // --- Other channels ---
            // 3D centre distance: hypot(2D-edge-distance, layer-z-gap). Same
            // plate only; different plates have the silicone gap between
            // them, not a printed wall.
            for other in edges where other.layer.plate == edge.layer.plate {
                if other.netId == edge.netId, other.segmentIndex == edge.segmentIndex { continue }
                // Same-net pairs (any layer) are intentionally meant to fuse
                // — two segments of the same net are part of one electrical
                // node, so the "wall" between them isn't a wall at all. Skip
                // both same-layer (the routes overlap to merge) and cross-
                // layer (connected through a via, but mechanically free to
                // run as close as the print resolution allows).
                if other.netId == edge.netId { continue }
                // Same-layer different-net pairs are surfaced by the existing
                // `channelClearance` issue (same wall-vs-`minWallThickness`
                // test); don't double-report.
                if other.layer == edge.layer { continue }
                let dxy = segmentDistance(edge.a, edge.b, other.a, other.b)
                let depthDelta = abs(edge.layer.depth - other.layer.depth)
                let dz = Double(depthDelta) * (m.channelDiameter + m.interLayerWall)
                let centre = (dxy * dxy + dz * dz).squareRoot()
                let wall = centre - 2 * channelRadius
                if wall < threshold {
                    let pos = approachPoint(edge.a, edge.b, other.a, other.b)
                    emit(edge: edge, neighbor: .channel, gap: wall, position: pos)
                }
            }

            // --- Bores ---
            for bore in bores where bore.layer.plate == edge.layer.plate {
                // Bores on this segment's own net are part of the same
                // electrical node — the route is on its way to connect to
                // them (or already does, via another segment). Their walls
                // are supposed to fuse, not stay separate.
                if let boreNet = bore.netId, boreNet == edge.netId { continue }
                // Skip the bore that anchors this segment's endpoint — the
                // channel intentionally meets its pin's drop or via, no wall
                // to talk about. 0.1 mm matches the eps used elsewhere for
                // pin-coincidence checks.
                let touchesA = abs(edge.a.x - bore.position.x) < 0.1
                    && abs(edge.a.y - bore.position.y) < 0.1
                let touchesB = abs(edge.b.x - bore.position.x) < 0.1
                    && abs(edge.b.y - bore.position.y) < 0.1
                if touchesA || touchesB { continue }
                let dxy = pointSegmentDistance(bore.position, edge.a, edge.b)
                // 3D wall: the channel runs at its layer's midline Z; the bore
                // occupies [zLo, zHi]. When the channel's Z sits outside that
                // band the vertical gap (`dz`) adds to the separation, so a
                // buried depth-1 channel clears a shallow depth-0 pad / via
                // instead of tripping a phantom thin wall.
                let cz = m.midZ(for: edge.layer)
                let dz = max(0, max(bore.zLo - cz, cz - bore.zHi))
                let centre = (dxy * dxy + dz * dz).squareRoot()
                let wall = centre - channelRadius - bore.radius
                if wall < threshold {
                    emit(edge: edge, neighbor: .bore, gap: wall, position: bore.position)
                }
            }
        }

        return issues
    }

    /// One segment of the printed plate's actual outer edge.
    fileprivate struct OutlineEdge { let a: Point; let b: Point }

    /// Returns the outer polygon edges of the printed plate, with each
    /// connector protrusion punched out from the rectangular `boardOutline`.
    /// At V1 there's at most one connector per edge (DRC enforces / the
    /// plan locks it), but the helper sorts by `offsetAlongEdge` so
    /// multiple protrusions on the same edge would compose cleanly.
    /// Edges with no connectors stay as a single straight segment.
    fileprivate static func outerBoundaryEdges(in doc: CircuitDocument) -> [OutlineEdge] {
        let outline = doc.physical.boardOutline
        let m = doc.manufacturing

        // Per-connector protrusion footprint, expressed in offsets along
        // its anchor edge and outward-extent depth. `halfRow` matches
        // `ComponentKind.connectorFootprint` so the polygon punches out
        // exactly the connector's CAD bounding rect.
        struct P {
            let edge: Edge
            let centre: Double   // offsetAlongEdge of the anchor
            let halfRow: Double
            let outward: Double
        }
        var byEdge: [Edge: [P]] = [:]
        for placement in doc.physical.placements {
            guard let comp = doc.logic.components.first(where: { $0.id == placement.componentId }),
                  comp.kind == .connector,
                  let anchor = placement.edgeAnchor
            else { continue }
            let n = max(1, comp.connectorPinCount ?? 1)
            let endCapY = ComponentKind.connectorEndCapLocalY(pinCount: n)
            let headRadius = ScrewGeometry.headDiameter / 2
            let halfRow = endCapY + headRadius + m.minWallThickness
            let outward = ComponentKind.connectorOutwardExtent(manufacturing: m)
            byEdge[anchor.edge, default: []].append(P(
                edge: anchor.edge,
                centre: anchor.offsetAlongEdge,
                halfRow: halfRow,
                outward: outward
            ))
        }
        for k in byEdge.keys { byEdge[k]?.sort { $0.centre < $1.centre } }

        var out: [OutlineEdge] = []

        /// Walk one edge of the rectangle from `start` to `end`, inserting
        /// each protrusion's three outer faces in place of the spans they
        /// cover. `axis` selects the coord that varies along the edge
        /// (.x for north/south, .y for east/west); `outwardNormal` is the
        /// unit vector that points away from the plate.
        func walkEdge(start: Point, end: Point, axisIsX: Bool,
                      fixed: Double, outwardNormalX: Double, outwardNormalY: Double,
                      protrusions: [P]) {
            // Sorted offsets along the edge of each protrusion's [near, far] span.
            let total = axisIsX ? (end.x - start.x) : (end.y - start.y)
            let sign: Double = total >= 0 ? 1 : -1
            var cursor: Double = 0   // distance traveled from start
            func pointAt(_ d: Double) -> Point {
                axisIsX
                    ? Point(x: start.x + sign * d, y: fixed)
                    : Point(x: fixed, y: start.y + sign * d)
            }
            for p in protrusions {
                let near = p.centre - p.halfRow
                let far  = p.centre + p.halfRow
                if near > cursor {
                    out.append(.init(a: pointAt(cursor), b: pointAt(near)))
                }
                // Inner-to-outer (perpendicular to the edge, away from the plate).
                let outerNear = Point(
                    x: pointAt(near).x + outwardNormalX * p.outward,
                    y: pointAt(near).y + outwardNormalY * p.outward
                )
                let outerFar = Point(
                    x: pointAt(far).x + outwardNormalX * p.outward,
                    y: pointAt(far).y + outwardNormalY * p.outward
                )
                out.append(.init(a: pointAt(near), b: outerNear))
                out.append(.init(a: outerNear, b: outerFar))
                out.append(.init(a: outerFar, b: pointAt(far)))
                cursor = max(cursor, far)
            }
            let endDist = abs(total)
            if cursor < endDist {
                out.append(.init(a: pointAt(cursor), b: pointAt(endDist)))
            }
        }

        // South edge: walk from west corner (minX, minY) eastward; outward = -Y.
        walkEdge(
            start: Point(x: outline.minX, y: outline.minY),
            end:   Point(x: outline.maxX, y: outline.minY),
            axisIsX: true, fixed: outline.minY,
            outwardNormalX: 0, outwardNormalY: -1,
            protrusions: byEdge[.south] ?? []
        )
        // East edge: walk from south corner (maxX, minY) northward; outward = +X.
        walkEdge(
            start: Point(x: outline.maxX, y: outline.minY),
            end:   Point(x: outline.maxX, y: outline.maxY),
            axisIsX: false, fixed: outline.maxX,
            outwardNormalX: 1, outwardNormalY: 0,
            protrusions: byEdge[.east] ?? []
        )
        // North edge: walk from east corner (maxX, maxY) westward; outward = +Y.
        // EdgeAnchor.offsetAlongEdge is measured from the west end at +X
        // (see `EdgeAnchor.worldPosition`), so we walk +X here too and the
        // protrusion offsets line up with the world coords directly.
        walkEdge(
            start: Point(x: outline.minX, y: outline.maxY),
            end:   Point(x: outline.maxX, y: outline.maxY),
            axisIsX: true, fixed: outline.maxY,
            outwardNormalX: 0, outwardNormalY: 1,
            protrusions: byEdge[.north] ?? []
        )
        // West edge: offsetAlongEdge is measured from the south end at +Y
        // (per `EdgeAnchor.worldPosition`), so walk south-to-north here.
        walkEdge(
            start: Point(x: outline.minX, y: outline.minY),
            end:   Point(x: outline.minX, y: outline.maxY),
            axisIsX: false, fixed: outline.minX,
            outwardNormalX: -1, outwardNormalY: 0,
            protrusions: byEdge[.west] ?? []
        )
        return out
    }
}
