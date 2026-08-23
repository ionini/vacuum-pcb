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

/// What a testing point's vertical bore is too close to. The bore is a hole
/// straight out to the plate's outer face — it exists only in the 3D plate
/// geometry (like a port outlet), so neither side of the clash is drawn on the
/// 2D physical layer.
enum TestPointNeighbor: String, Hashable {
    /// A foreign net's routed channel whose Z band the vertical bore passes
    /// through on the same plate.
    case channel
    /// Another testing point's bore on the same plate.
    case testPoint
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
        /// Tints the pulse: red for errors, orange for warnings.
        var severity: Severity = .error
        /// Short measurement shown in a chip next to the pulse — the wall
        /// that tripped the check ("0.32 mm"), when the issue has one.
        var label: String? = nil
        /// Route segments to glow in the severity colour while the focus is
        /// live — both halves of a clearance pair, not just the selected one.
        var glowSegments: [PhysicalSelection.RouteSegmentRef] = []
    }

    /// How bad an issue is. Wall checks classify each finding: below
    /// `minWallThickness` the print is expected to fail (`.error`); between
    /// `minWallThickness` and `preferredWallThickness` it prints but with
    /// less margin than the board asked for (`.warning`). Topology and
    /// electrical checks are always `.error`.
    enum Severity: Hashable, Comparable {
        case warning
        case error
    }

    struct Issue: Identifiable, Hashable {
        let id = UUID()
        let netId: UUID
        let netLabel: String
        let kind: Kind
        var severity: Severity = .error

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
            /// segment so we can highlight both on click. `position` is the
            /// midpoint of the thin wall itself (closest approach of the two
            /// offending edges) — where the focus ping lands.
            case channelClearance(
                otherNetId: UUID,
                otherNetLabel: String,
                layer: Layer,
                wall: Double,
                selfSegmentIndex: Int,
                otherSegmentIndex: Int,
                position: Point
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
            /// A testing point's vertical bore (channel midline → plate outer
            /// face) passes within `minWallThickness` of a foreign net's
            /// channel or another testing point on the same plate. The bore
            /// exists only in the 3D geometry, so — like `portBoreClearance` —
            /// the clash is invisible on the 2D layer. `testPointId` is the
            /// offending point (for canvas selection); `otherLabel` is the
            /// foreign net's label (channel) or the other point's name.
            case testPointClearance(
                testPointId: UUID,
                testPointName: String,
                neighbor: TestPointNeighbor,
                otherLabel: String,
                layer: Layer,
                wall: Double,
                position: Point
            )
            /// A wall check finding where at least one side lives *inside a
            /// placed sub-part* — detected on the flattened doc (like
            /// `crossNetMerge`), because sub-part internals print with THIS
            /// document's constants, and the per-file check of the library
            /// part can't see the parent's routes, board edge, or a second
            /// sub-part placed next to it. `neighbor` reuses the thin-wall
            /// vocabulary (.channel / .outerFace / .bore); labels carry the
            /// sub-part instance chain ("U1.n3"). `otherNetId` is the flat
            /// net of the other side when it has one (nil for the outer
            /// face), used with the label to select whatever the user can
            /// act on in the parent canvas.
            case subpartWall(
                neighbor: ThinWallNeighbor,
                otherNetId: UUID?,
                otherLabel: String?,
                layer: Layer,
                wall: Double,
                position: Point
            )
            /// A transistor / LED pin bore sits measurably off-centre from
            /// the channel that plumbs it. Two ways to get there, same
            /// printed defect:
            ///
            /// - A *hoisted sub-part* pin: the flatten computes pin
            ///   positions with the PARENT's constants (what PlateBuilder
            ///   drills), but the sub-part's internal routes were drawn
            ///   against the library file's own — when they disagree
            ///   (padsOffset, usually) the drop bore lands offset from its
            ///   channel end. `componentLabel` carries the instance chain
            ///   ("U2.Q1").
            /// - A *top-level* pin of this document: the pads constants
            ///   changed after the routes were drawn, so the file's own
            ///   route endpoints are stranded off the bores this same file
            ///   drills. `componentLabel` is the bare label ("Q1").
            ///
            /// Bore and channel still fuse while the drift stays under a
            /// channel radius, so the board "works", but the effective
            /// aperture shrinks and nothing else surfaces the mismatch.
            case subpartPinDrift(
                componentLabel: String,
                pinKey: String,
                drift: Double,
                layer: Layer,
                position: Point
            )

            /// A piece of this net's printed channel network forms its own
            /// sealed cavity: no channel, same-plate via, resistor or
            /// cross-silicone bridge joins it to the rest of the net, and it
            /// has no opening of its own (port / vent / source / connector
            /// bore, testing point). Whatever taps into the fragment is cut
            /// off on the printed board. The classic cause is a route drawn
            /// against a sub-part pin that later moved: the endpoint still
            /// sits inside the ratsnest snap tolerance (a dimple radius), so
            /// connectivity reads green, but the print only heals gaps up to
            /// a channel diameter — the channel dead-ends short of the bore.
            case sealedCavity(
                refs: [String],   // hole refs inside the fragment, worst first
                layer: Layer,
                position: Point   // first hole — where to ping
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
            case .channelClearance(_, let other, let layer, let wall, _, _, _):
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
            case let .testPointClearance(_, tpName, neighbor, otherLabel, layer, wall, _):
                let what = neighbor == .channel ? "channel \(otherLabel)" : "test point \(otherLabel)"
                let wallTxt = wall < 0.01 ? "touching" : "\(String(format: "%.2f", wall)) mm wall"
                return "\(tpName) → \(what) on \(layer.uiLabel): \(wallTxt)"
            case let .subpartWall(neighbor, _, otherLabel, layer, wall, _):
                let wallTxt = wall < 0.01 ? "touching" : "\(String(format: "%.2f", wall)) mm wall"
                let what: String
                switch neighbor {
                case .outerFace: what = "board edge"
                case .channel:   what = otherLabel ?? "another channel"
                case .bore:      what = otherLabel.map { "\($0) bore" } ?? "a bore"
                }
                return "\(netLabel) ↔ \(what) on \(layer.uiLabel): \(wallTxt) (sub-part)"
            case let .subpartPinDrift(componentLabel, pinKey, drift, layer, _):
                // The instance-chain prefix is what distinguishes a hoisted
                // sub-part pin from one of this document's own (same
                // convention `physicalSelection` uses); only the cause hint
                // differs, since a top-level pin drifted against this very
                // file's routes, not a library's.
                let cause = componentLabel.contains(".")
                    ? "sub-part routed with different constants — check padsOffset"
                    : "routed with different constants — check padsOffset"
                return "\(componentLabel) pin \(pinKey) bore \(String(format: "%.2f", drift)) mm "
                    + "off its channel on \(layer.uiLabel) (\(cause))"
            case let .sealedCavity(refs, layer, pos):
                let shown = refs.prefix(3).joined(separator: ", ")
                let more = refs.count > 3 ? " +\(refs.count - 3) more" : ""
                return "\(netLabel): \(shown)\(more) print as a sealed cavity on \(layer.uiLabel) "
                    + "near (\(String(format: "%.1f", pos.x)), \(String(format: "%.1f", pos.y))) — "
                    + "no channel reaches the rest of the net"
            }
        }

        /// Compact measurement for canvas chips: the printed wall that
        /// tripped a clearance / wall check ("0.32 mm", "touching"). Nil for
        /// kinds that don't measure a gap.
        var gapText: String? {
            let gap: Double
            switch kind {
            case let .channelClearance(_, _, _, wall, _, _, _): gap = wall
            case let .thinWall(_, _, g, _, _): gap = g
            case let .screwClearance(_, _, g, _): gap = g
            case let .viaSpacing(_, _, _, g, _): gap = g
            case let .viaPad(_, _, g, _): gap = g
            case let .stencilHole(_, g, _): gap = g
            case let .portBoreClearance(_, _, _, _, _, _, _, wall, _): gap = wall
            case let .testPointClearance(_, _, _, _, _, wall, _): gap = wall
            case let .subpartWall(_, _, _, _, wall, _): gap = wall
            default: return nil
            }
            return gap < 0.01 ? "touching" : String(format: "%.2f mm", gap)
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
        case let .channelClearance(otherNetId, _, _, _, selfSeg, otherSeg, _):
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
            return flattenedSidesSelection(
                [(issue.netId, issue.netLabel), (otherNetId, otherLabel)],
                in: document
            )
        case let .subpartWall(_, otherNetId, otherLabel, _, _, _):
            var sides: [(netId: UUID?, label: String)] = [(issue.netId, issue.netLabel)]
            if otherLabel != nil || otherNetId != nil {
                sides.append((otherNetId, otherLabel ?? ""))
            }
            return flattenedSidesSelection(sides, in: document)
        case let .subpartPinDrift(componentLabel, _, _, _, _):
            // The instance-chain prefix ("U2.Q1" → "U2") selects the sub-part
            // placement the drifted pin lives in; a bare label is one of this
            // document's own components, so select it directly.
            if !componentLabel.contains("."),
               let own = document.logic.components.first(where: { $0.label == componentLabel }) {
                return .placement(own.id)
            }
            return flattenedSidesSelection([(nil, componentLabel)], in: document)
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
        case let .testPointClearance(testPointId, _, _, _, _, _, _):
            // Select the offending testing point so the user can drag it along
            // its rail (or press F) to clear the wall.
            return .testPoint(testPointId)
        case let .sealedCavity(refs, _, _):
            // The fragment's holes name the components it strands (hoisted
            // refs like "U2.Q3.a" select the sub-part instance; a bare ref is
            // one of this document's own components). Add the net's own pins
            // so a parent-level net highlights its endpoints too.
            var sides: [(netId: UUID?, label: String)] = [(issue.netId, issue.netLabel)]
            sides.append(contentsOf: refs.map { (nil, $0) })
            return flattenedSidesSelection(sides, in: document)
        }
    }

    /// For each side of a flattened-doc finding (cross-net merge, sub-part
    /// wall), highlight whatever the user can act on in the unflattened
    /// canvas:
    ///   * net at the parent level → all its pins (placements set)
    ///   * net hoisted out of a sub-part → that instance's placement,
    ///     identified by the label prefix ("U1.n3" → component labelled
    ///     "U1"). Lets the user jump into the sub-part view where the
    ///     actual offending segment lives.
    private static func flattenedSidesSelection(
        _ sides: [(netId: UUID?, label: String)],
        in document: CircuitDocument
    ) -> PhysicalSelection? {
        let parentNets = Set(document.logic.nets.map(\.id))
        var sel = PhysicalSelection()
        for side in sides {
            if let netId = side.netId, parentNets.contains(netId),
               let net = document.logic.nets.first(where: { $0.id == netId }) {
                sel.placements.formUnion(net.pins.map(\.componentId))
                continue
            }
            if let dot = side.label.firstIndex(of: "."),
               let instance = document.logic.components.first(where: {
                   $0.kind == .subpart && $0.label == String(side.label[..<dot])
               }) {
                sel.placements.insert(instance.id)
            }
        }
        return sel.isEmpty ? nil : sel
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
        case let .channelClearance(_, _, layer, _, _, _, pos):
            return (pos, layer)
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
        case let .testPointClearance(_, _, _, _, layer, _, pos):
            return (pos, layer)
        case let .subpartWall(_, _, _, layer, _, pos):
            return (pos, layer)
        case let .subpartPinDrift(_, _, _, layer, pos):
            return (pos, layer)
        case let .sealedCavity(_, layer, pos):
            return (pos, layer)
        case .unplacedPin, .noRouteDrawn, .matingIncompatible, .matingDoubleBooked:
            return nil
        }
    }

    /// Route segments to glow in the severity colour while an issue is
    /// focused — both halves of a clearance pair, so the user sees exactly
    /// which two channels pinch (the plain selection only accents the self
    /// segment). Only kinds that address top-level segments participate;
    /// sub-part internals aren't addressable in the parent canvas.
    static func glowSegments(for issue: Issue) -> [PhysicalSelection.RouteSegmentRef] {
        switch issue.kind {
        case let .channelClearance(otherNetId, _, _, _, selfSeg, otherSeg, _):
            return [
                .init(netId: issue.netId, segmentIndex: selfSeg),
                .init(netId: otherNetId, segmentIndex: otherSeg),
            ]
        case let .thinWall(_, _, _, segIdx, _),
             let .orphanVia(_, segIdx):
            return [.init(netId: issue.netId, segmentIndex: segIdx)]
        default:
            return []
        }
    }

    /// A persistent wall-violation badge on the physical canvas — every
    /// finding from the wall / clearance family (the checks that measure a
    /// printed gap) drops one at its narrowest spot, so thin walls are
    /// visible at a glance instead of one sidebar click at a time.
    struct CanvasMarker: Identifiable, Hashable {
        let id: UUID
        let position: Point
        let layer: Layer
        let severity: Severity
        let label: String?
        /// Stencil-sheet findings show in silicone-sheet mode instead of
        /// following the per-layer filter — their geometry lives on the sheet.
        let onStencil: Bool
    }

    static func canvasMarkers(for issues: [Issue], in document: CircuitDocument) -> [CanvasMarker] {
        issues.compactMap { issue in
            switch issue.kind {
            case .channelClearance, .thinWall, .screwClearance, .viaSpacing,
                 .viaPad, .stencilHole, .portBoreClearance, .testPointClearance,
                 .subpartWall:
                break
            default:
                return nil
            }
            guard let (pos, layer) = focusPosition(for: issue, in: document) else { return nil }
            let onStencil: Bool
            if case .stencilHole = issue.kind { onStencil = true } else { onStencil = false }
            return CanvasMarker(
                id: issue.id, position: pos, layer: layer,
                severity: issue.severity, label: issue.gapText,
                onStencil: onStencil
            )
        }
    }

    static func check(_ document: CircuitDocument) -> [Issue] {
        var issues: [Issue] = []
        for net in document.logic.nets {
            issues.append(contentsOf: checkNet(net, in: document))
        }

        // One shared flatten for every geometry check — sub-part internals
        // print with *this* document's constants, so proximity must be
        // checked here, not (only) in each library file. Socket-mated
        // assemblies are the exception: their sub-parts stack at one origin
        // and print separately, so flattened proximity is meaningless —
        // the wall checks fall back to the top-level doc there.
        // (`crossNetMerge` and the stencil check keep their historical
        // always-flattened behaviour.)
        let (flat, flatLabels) = document.flattenedWithLabels()
        let useFlat = document.logic.matings.isEmpty
        let geoDoc = useFlat ? flat : document
        let geoLabels = useFlat ? flatLabels : nil
        // Routes at index < parentRouteCount (and components in the parent's
        // id set) are the document's own; everything past that was hoisted
        // out of a sub-part by the flatten.
        let parentRouteCount = document.physical.routes.count
        let parentComponentIds = Set(document.logic.components.map(\.id))

        issues.append(contentsOf: clearanceIssues(
            in: geoDoc, parentRouteCount: parentRouteCount, labels: geoLabels))
        issues.append(contentsOf: crossNetMergeIssues(flat: flat, labels: flatLabels))
        issues.append(contentsOf: thinWallIssues(
            in: geoDoc, parent: document, parentRouteCount: parentRouteCount,
            parentComponentIds: parentComponentIds, labels: geoLabels))
        issues.append(contentsOf: matingIssues(in: document))
        issues.append(contentsOf: screwClearanceIssues(in: geoDoc))
        issues.append(contentsOf: viaClearanceIssues(in: geoDoc, labels: geoLabels))
        issues.append(contentsOf: stencilHoleIssues(flat: flat))
        issues.append(contentsOf: portBoreClearanceIssues(in: geoDoc, labels: geoLabels))
        issues.append(contentsOf: testPointClearanceIssues(in: geoDoc, labels: geoLabels))
        issues.append(contentsOf: pinDriftIssues(
            in: geoDoc, parentRouteCount: parentRouteCount, labels: geoLabels))
        if useFlat {
            issues.append(contentsOf: sealedCavityIssues(in: document))
        }
        return issues
    }

    // MARK: - Two-tier wall thresholds

    /// Distance the wall checks scan out to: the hard limit, or the comfort
    /// wall when the board asks for one.
    private static func wallScanThreshold(_ m: ManufacturingConstants) -> Double {
        max(m.minWallThickness, m.preferredWallThickness)
    }

    /// Classifies a wall finding: below the hard limit the print is expected
    /// to fail (error); between the limits it's printable but thinner than
    /// the board's comfort wall (warning).
    private static func wallSeverity(_ wall: Double, _ m: ManufacturingConstants) -> Severity {
        wall < m.minWallThickness ? .error : .warning
    }

    // MARK: - Stencil cutting-sheet crowding

    /// Flags places where a silicone cutting *stencil* would tear: a fluid
    /// through-hole sits within `minWallThickness` of another hole in the same
    /// cut piece. The silicone is cut into separate pieces — the board sheet
    /// (cross-silicone vias, standalone screw bores, dimples) and one gasket
    /// per `.bottomExtend` connector (its pin tubes + end-cap screws, at the
    /// gasket paddings — see `ConnectorGasket`) — and holes only threaten each
    /// other *within* a piece: a connector hole near a board via is fine, the
    /// pieces are cut apart there anyway. Stencil-only — the printed plate
    /// bores are unaffected by any padding, so this never duplicates the plate
    /// checks. Runs on the *flattened* design because the stencils are built
    /// flattened (they punch sub-part vias too), so a top-level-only pass
    /// would miss almost every hole. The flatten is computed once in `check`
    /// and passed in.
    ///
    /// Every pair measured has a fluid hole on at least one side, deliberately:
    /// what's at stake is the silicone land a via or pin needs to seal against,
    /// which is why the screw paddings have to be in the screw radii here —
    /// a relief hole widened into a via's land leaks. Two *screw* holes merging
    /// is not a defect (nothing seals or flows between them), so opening the
    /// screw padding up never flags on its own.
    private static func stencilHoleIssues(flat: CircuitDocument) -> [Issue] {
        let m = flat.manufacturing
        guard m.stencilThickness > 0, m.minWallThickness > 0 else { return [] }
        let threshold = m.minWallThickness

        struct Hole { let pos: Point; let radius: Double; let label: String }

        func dist(_ a: Point, _ b: Point) -> Double {
            ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
        }
        var issues: [Issue] = []
        func emit(_ pos: Point, _ gap: Double, _ detail: String) {
            issues.append(Issue(netId: UUID(), netLabel: "Stencil",
                                kind: .stencilHole(position: pos, gap: max(0, gap), detail: detail)))
        }
        // Pair check within ONE cut piece: fluid holes against each other and
        // against the piece's non-fluid neighbours.
        func check(padded: [Hole], others: [Hole]) {
            for i in 0..<padded.count {
                for j in (i + 1)..<padded.count {
                    let wall = dist(padded[i].pos, padded[j].pos) - padded[i].radius - padded[j].radius
                    if wall < threshold {
                        emit(midpoint(padded[i].pos, padded[j].pos), wall,
                             "\(padded[i].label) hole ↔ \(padded[j].label) hole")
                    }
                }
                for o in others {
                    let wall = dist(padded[i].pos, o.pos) - padded[i].radius - o.radius
                    if wall < threshold { emit(midpoint(padded[i].pos, o.pos), wall, "\(padded[i].label) hole ↔ \(o.label)") }
                }
            }
        }

        let comps = Dictionary(flat.logic.components.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Board sheet. Fluid holes are the cross-silicone vias, enlarged by
        // `stencilViaPadding` — the holes whose surrounding silicone has to
        // seal. Their non-fluid neighbours: standalone screw clearance shafts
        // (as wide as the stencil actually cuts them, so `stencilScrewPadding`
        // is in the radius) and the transistor / LED dimples the silicone
        // deflects into.
        let paddedRadius = (m.channelDiameter + m.stencilViaPadding) / 2
        let screwRadius = (m.screwThroughDiameter + m.stencilScrewPadding) / 2
        let boardPadded = flat.physical.crossSiliconeViaPositions().map {
            Hole(pos: $0, radius: paddedRadius, label: "via")
        }
        var boardOthers: [Hole] = []
        for pl in flat.physical.placements {
            guard let c = comps[pl.componentId] else { continue }
            switch c.kind {
            case .screw:
                boardOthers.append(Hole(pos: pl.position, radius: screwRadius, label: "screw"))
            case .transistor:
                boardOthers.append(Hole(pos: pl.position, radius: m.dimpleDiameter / 2, label: "transistor dimple"))
            case .led:
                boardOthers.append(Hole(pos: pl.position, radius: m.ledDimpleDiameter / 2, label: "LED dimple"))
            default:
                break
            }
        }
        check(padded: boardPadded, others: boardOthers)

        // One gasket piece per `.bottomExtend` connector: its pin tubes (fluid)
        // against its end-cap screw bores, both at the gasket diameters
        // `PlateBuilder` actually cuts (`ConnectorGasket`, the shared source).
        for pl in flat.physical.placements {
            guard let c = comps[pl.componentId],
                  c.kind == .connector,
                  (c.connectorRole ?? .bottomExtend) == .bottomExtend,
                  !(c.connectorDebugPorts ?? false)   // debug bores never cross the sheet
            else { continue }
            let fp = c.footprint(m, snapshots: flat.librarySnapshots)
            let pinCentres = fp.pins.map { pl.worldPosition(of: $0) }
            let halfExt = fp.exclusionRect.size.width / 2
            let screwYs = ComponentKind.connectorScrewLocalYs(
                pinCount: c.connectorPinCount ?? 1,
                screwCount: c.connectorScrewCount ?? ComponentKind.connectorMinScrewCount
            )
            let screwCentres = screwYs.map { sy in
                pl.worldPosition(of: FootprintPin(
                    key: "_endcap", offset: Point(x: halfExt, y: sy), relativeLayer: .same
                ))
            }
            guard let gasket = ConnectorGasket.layout(
                pinCentres: pinCentres, screwCentres: screwCentres, m: m
            ) else { continue }
            check(
                padded: gasket.pinHoles.map {
                    Hole(pos: $0.position, radius: $0.diameter / 2, label: "connector pin")
                },
                others: gasket.screwHoles.map {
                    Hole(pos: $0.position, radius: $0.diameter / 2, label: "end-cap screw")
                }
            )
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
        /// User-facing name of what this bore belongs to — the (possibly
        /// sub-part-prefixed) net label for a via, the owning component's
        /// label for a pad. Quoted by `.subpartWall` issue text.
        var label: String? = nil
        /// True when the bore came out of a placed sub-part (hoisted route
        /// via or hoisted transistor / LED placement).
        var fromSubpart: Bool = false
    }

    /// Collects every via bore and every transistor / LED pad bore in the
    /// document, on their resolved layers, tagged with the net (and component)
    /// they belong to so the clearance checks can skip same-net pairs that are
    /// meant to fuse. Via waypoints are grouped by (net, XY) to learn the full
    /// layer set each via spans, then emitted as one bore per plate with the
    /// Z band it occupies there — so an intra-plate via doesn't pretend to
    /// reach the silicone face.
    ///
    /// When `check` passes a flattened doc, `parentComponentIds` /
    /// `parentRouteCount` mark which bores were hoisted out of a sub-part.
    /// Hoisted transistor / LED pins belong to nets that don't exist in
    /// `logic.nets` (flatten re-mints route net ids without hoisting the
    /// `Net` objects), so their net attribution falls back to the route
    /// whose segment endpoint sits on the pin — without it, a sub-part
    /// transistor's own supply channel would read as a foreign bore.
    private static func collectBores(
        in doc: CircuitDocument,
        parentComponentIds: Set<UUID>? = nil,
        parentRouteCount: Int = .max,
        labelOverrides: [UUID: String]? = nil
    ) -> [Bore] {
        let m = doc.manufacturing
        let channelRadius = m.channelDiameter / 2
        func faceZ(_ plate: Plate) -> Double {
            plate == .top ? m.siliconeThickness / 2 : -m.siliconeThickness / 2
        }
        var pinToNet: [PinRef: UUID] = [:]
        for net in doc.logic.nets {
            for pinRef in net.pins { pinToNet[pinRef] = net.id }
        }
        let netLabels = Dictionary(uniqueKeysWithValues: doc.logic.nets.map { ($0.id, $0.label) })
        func label(of netId: UUID) -> String? {
            labelOverrides?[netId] ?? netLabels[netId]
        }
        // Geometry-based net fallback for hoisted pins (flattened mode only):
        // a pin belongs to the net whose route is plumbed to it, and that
        // route doesn't necessarily *end* there — it can pass straight
        // through (pin mid-polyline), carry the parent's net id after
        // boundary unification, or sit off-centre when the parent's
        // padsOffset differs from the one the sub-part was routed with (the
        // flat doc computes pin positions with the parent's constants). The
        // physical criterion is overlap — bore and channel fuse into one
        // node — so match the *closest* route polyline within a channel
        // radius on the pin's own plate. Closest-wins keeps a genuinely
        // foreign channel grazing the pin from stealing the attribution
        // (its distance is larger than the plumbed net's).
        var routeGeometry: [(a: Point, b: Point, netId: UUID, plate: Plate)] = []
        if parentRouteCount != .max {
            for route in doc.physical.routes {
                for seg in route.segments {
                    let pts = seg.waypoints
                    guard pts.count >= 2 else { continue }
                    for i in 0..<(pts.count - 1) {
                        routeGeometry.append((pts[i].position, pts[i + 1].position,
                                              route.netId, seg.layer.plate))
                    }
                }
            }
        }
        func plumbedNet(at p: Point, plate: Plate) -> UUID? {
            var bestNet: UUID?
            var bestDistance = channelRadius
            for e in routeGeometry where e.plate == plate {
                let d = pointSegmentDistance(p, e.a, e.b)
                if d < bestDistance { bestDistance = d; bestNet = e.netId }
            }
            return bestNet
        }
        var bores: [Bore] = []

        struct ViaGroup {
            var position: Point
            var layers: Set<Layer>
            var netId: UUID
            var fromSubpart: Bool
        }
        var viaGroups: [ViaGroup] = []
        for (routeIndex, route) in doc.physical.routes.enumerated() {
            let fromSubpart = routeIndex >= parentRouteCount
            for segment in route.segments {
                for wp in segment.waypoints where wp.kind == .via {
                    if let i = viaGroups.firstIndex(where: {
                        $0.netId == route.netId
                            && abs($0.position.x - wp.position.x) < 0.05
                            && abs($0.position.y - wp.position.y) < 0.05
                    }) {
                        viaGroups[i].layers.insert(segment.layer)
                        viaGroups[i].fromSubpart = viaGroups[i].fromSubpart || fromSubpart
                    } else {
                        viaGroups.append(ViaGroup(
                            position: wp.position, layers: [segment.layer],
                            netId: route.netId, fromSubpart: fromSubpart
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
                                  zLo: zs.min()!, zHi: zs.max()!,
                                  label: label(of: group.netId),
                                  fromSubpart: group.fromSubpart))
            }
        }
        for placement in doc.physical.placements {
            guard let comp = doc.logic.components.first(where: { $0.id == placement.componentId })
            else { continue }
            let fromSubpart = parentComponentIds.map { !$0.contains(comp.id) } ?? false
            switch comp.kind {
            case .transistor, .led:
                let fp = comp.footprint(m, snapshots: doc.librarySnapshots)
                for pin in fp.pins {
                    let ref = PinRef(componentId: placement.componentId, pinKey: pin.key)
                    let pinLayer = placement.resolvedLayer(of: pin, on: comp)
                    let face = faceZ(pinLayer.plate)
                    // Drop bore runs from the silicone face to its channel
                    // midline; a transistor gate / LED indicator carves a dome
                    // whose defining sphere is centred `sphereOffset` *outside*
                    // the plate (in the silicone gap), so the cap intrudes
                    // radius − offset past the face. Matches the cutter in
                    // `PlateBuilder.dimpleMesh` / `ledDimpleMesh`.
                    var reach = abs(m.midZ(for: pinLayer) - face)
                    if comp.kind == .transistor, pin.key == "gate" {
                        reach = max(reach, m.dimpleDiameter / 2 - m.dimpleSphereOffset)
                    } else if comp.kind == .led {
                        reach = max(reach, m.ledDimpleDiameter / 2 - m.ledDimpleDepth)
                    }
                    let zEnd = face + (pinLayer.plate == .top ? reach : -reach)
                    let world = placement.worldPosition(of: pin)
                    let netId = pinToNet[ref]
                        ?? (fromSubpart ? plumbedNet(at: world, plate: pinLayer.plate) : nil)
                    bores.append(Bore(
                        position: world,
                        radius: channelRadius,
                        layer: pinLayer,
                        netId: netId,
                        componentId: placement.componentId,
                        zLo: min(face, zEnd), zHi: max(face, zEnd),
                        label: comp.label.isEmpty ? nil : comp.label,
                        fromSubpart: fromSubpart
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
        let threshold = wallScanThreshold(m)
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
        // Worst gap per (screw, neighbor kind), so the reported severity is
        // the pair's true one when a screw grazes both a warning-grade and
        // an error-grade wall.
        var best: [ReportKey: (label: String, p: Point, gap: Double)] = [:]
        func record(_ screw: (id: UUID, label: String, p: Point, headSide: Plate),
                    _ neighbor: ScrewNeighbor, _ gap: Double) {
            let key = ReportKey(screwId: screw.id, neighbor: neighbor)
            if let current = best[key], current.gap <= gap { return }
            best[key] = (screw.label, screw.p, gap)
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
                nutDepth: m.screwNutDepth,
                throughDiameter: m.screwThroughDiameter, headSide: screw.headSide
            )
            for edge in edges {
                let dxy = pointSegmentDistance(screw.p, edge.a, edge.b)
                let cz = m.midZ(for: edge.layer)
                let wall = minWall(columns, plate: edge.layer.plate,
                                   dxy: dxy, fLo: cz, fHi: cz, featureRadius: channelRadius)
                if wall < threshold { record(screw, .route, wall) }
            }
            for bore in bores {
                let dx = screw.p.x - bore.position.x, dy = screw.p.y - bore.position.y
                let dxy = (dx * dx + dy * dy).squareRoot()
                let wall = minWall(columns, plate: bore.layer.plate,
                                   dxy: dxy, fLo: bore.zLo, fHi: bore.zHi, featureRadius: bore.radius)
                if wall < threshold { record(screw, bore.componentId == nil ? .via : .pad, wall) }
            }
        }
        let issues = best.map { key, found in
            Issue(netId: UUID(), netLabel: found.label,
                  kind: .screwClearance(screwId: key.screwId, neighbor: key.neighbor,
                                        gap: max(0, found.gap), position: found.p),
                  severity: wallSeverity(found.gap, m))
        }
        return issues.sorted { $0.summary < $1.summary }
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
    private static func viaClearanceIssues(
        in doc: CircuitDocument,
        labels labelOverrides: [UUID: String]? = nil
    ) -> [Issue] {
        let m = doc.manufacturing
        let threshold = wallScanThreshold(m)
        guard threshold > 0 else { return [] }
        var labels = Dictionary(uniqueKeysWithValues: doc.logic.nets.map { ($0.id, $0.label) })
        if let overrides = labelOverrides {
            labels.merge(overrides) { _, hoisted in hoisted }
        }

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
        var issues: [Issue] = []

        // via ↔ via (different nets, same plate, sharing plate height).
        // Worst wall per pair so the reported severity is the pair's true one.
        var bestVV: [PairKey: (a: Bore, b: Bore, wall: Double)] = [:]
        for i in 0..<vias.count {
            for j in (i + 1)..<vias.count {
                let a = vias[i], b = vias[j]
                guard a.layer.plate == b.layer.plate else { continue }
                guard let an = a.netId, let bn = b.netId, an != bn else { continue }
                guard zOverlaps(a, b) else { continue }
                let wall = dist(a.position, b.position) - a.radius - b.radius
                guard wall < threshold else { continue }
                let key = PairKey(an, bn, a.layer.plate)
                if let current = bestVV[key], current.wall <= wall { continue }
                bestVV[key] = (a, b, wall)
            }
        }
        for found in bestVV.values {
            let an = found.a.netId!, bn = found.b.netId!
            issues.append(Issue(
                netId: an, netLabel: labels[an] ?? "?",
                kind: .viaSpacing(otherNetId: bn, otherNetLabel: labels[bn] ?? "?",
                                  layer: found.a.layer, gap: max(0, found.wall),
                                  position: midpoint(found.a.position, found.b.position)),
                severity: wallSeverity(found.wall, m)
            ))
        }

        // via ↔ foreign transistor/LED pad (same plate, sharing plate height)
        let pads = bores.filter { $0.componentId != nil }
        struct VPKey: Hashable { let net: UUID; let comp: UUID; let plate: Plate }
        var bestVP: [VPKey: (via: Bore, pad: Bore, wall: Double)] = [:]
        for via in vias {
            guard let vn = via.netId else { continue }
            for pad in pads where pad.layer.plate == via.layer.plate {
                if pad.netId == vn { continue }   // same net: meant to connect
                guard zOverlaps(via, pad) else { continue }
                let wall = dist(via.position, pad.position) - via.radius - pad.radius
                guard wall < threshold else { continue }
                let key = VPKey(net: vn, comp: pad.componentId!, plate: via.layer.plate)
                if let current = bestVP[key], current.wall <= wall { continue }
                bestVP[key] = (via, pad, wall)
            }
        }
        for found in bestVP.values {
            let vn = found.via.netId!
            issues.append(Issue(
                netId: vn, netLabel: labels[vn] ?? "?",
                kind: .viaPad(padComponentId: found.pad.componentId!, layer: found.via.layer,
                              gap: max(0, found.wall), position: found.via.position),
                severity: wallSeverity(found.wall, m)
            ))
        }
        return issues.sorted { $0.summary < $1.summary }
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
            // Mechanical, not electrical: the pins still line up, but a
            // different screw count means the bolt holes don't. Allowed
            // (the mate is created) but flagged so the user notices.
            let aScrews = a.component.connectorScrewCount ?? ComponentKind.connectorMinScrewCount
            let bScrews = b.component.connectorScrewCount ?? ComponentKind.connectorMinScrewCount
            if aScrews != bScrews {
                issues.append(Issue(
                    netId: mating.id, netLabel: label,
                    kind: .matingIncompatible(reason: "screw counts don't match (\(aScrews) vs \(bScrews)); the bolt pattern won't line up")
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
        /// True when this edge was hoisted out of a placed sub-part by the
        /// flatten — its segment isn't addressable in the parent canvas, so
        /// findings involving it report as `.subpartWall` with an explicit
        /// position instead of segment indices.
        var fromSubpart: Bool = false
    }

    /// Walks every pair of route polyline edges; if two edges on the same
    /// plate-layer belong to different nets and the printed wall between them
    /// — centre distance minus both channel radii — is thinner than
    /// `minWallThickness` (error) or `preferredWallThickness` (warning), emit
    /// one issue per (net-pair, layer) at the pair's *worst* wall. We don't
    /// spam the sidebar with every offending segment; the user just needs to
    /// know "those two nets clash on top, look at the canvas".
    ///
    /// Diameter-aware on purpose: the reported number is the actual wall, not
    /// the centre-to-centre distance, so it lines up with `thinWall` (which
    /// defers the same-layer different-net case to here) instead of leaving a
    /// `channelDiameter`-thick blind spot. `minChannelSpacing` stays the
    /// auto-router's centre-to-centre keep-out — the *physical* limit is the
    /// wall, and that's what DRC enforces.
    ///
    /// Runs on the flattened doc (`check` passes it in): pairs of the
    /// document's own routes report exactly as before, pairs with at least
    /// one sub-part-internal side report as `.subpartWall`.
    private static func clearanceIssues(
        in doc: CircuitDocument,
        parentRouteCount: Int = .max,
        labels labelOverrides: [UUID: String]? = nil
    ) -> [Issue] {
        let m = doc.manufacturing
        let threshold = wallScanThreshold(m)
        guard threshold > 0 else { return [] }
        let channelRadius = m.channelDiameter / 2
        let edges = collectRouteEdges(in: doc, parentRouteCount: parentRouteCount,
                                      labelOverrides: labelOverrides)
        guard edges.count >= 2 else { return [] }

        struct PairKey: Hashable {
            let first: UUID, second: UUID, layer: Layer
            init(_ a: UUID, _ b: UUID, _ layer: Layer) {
                let ordered = a.uuidString < b.uuidString ? (a, b) : (b, a)
                self.first = ordered.0; self.second = ordered.1; self.layer = layer
            }
        }
        // Worst wall per pair, so a pair that grazes a warning-grade wall in
        // one spot and an error-grade wall in another reports the error.
        var best: [PairKey: (wall: Double, a: ChannelEdge, b: ChannelEdge)] = [:]
        for i in 0..<edges.count {
            for j in (i + 1)..<edges.count {
                let a = edges[i], b = edges[j]
                if a.netId == b.netId { continue }
                if a.layer != b.layer { continue }
                let d = segmentDistance(a.a, a.b, b.a, b.b)
                let wall = d - 2 * channelRadius
                guard wall < threshold else { continue }
                let key = PairKey(a.netId, b.netId, a.layer)
                if let cur = best[key], cur.wall <= wall { continue }
                best[key] = (wall, a, b)
            }
        }
        let issues = best.values.map { found -> Issue in
            let severity = wallSeverity(found.wall, m)
            if found.a.fromSubpart || found.b.fromSubpart {
                // Attribute the issue to the sub-part side ("U1.n3 ↔ n5"
                // reads better than the reverse when U1 is the stranger).
                let (s, o) = found.a.fromSubpart ? (found.a, found.b) : (found.b, found.a)
                return Issue(
                    netId: s.netId, netLabel: s.netLabel,
                    kind: .subpartWall(
                        neighbor: .channel, otherNetId: o.netId,
                        otherLabel: o.netLabel, layer: s.layer,
                        wall: max(0, found.wall),
                        position: approachPoint(s.a, s.b, o.a, o.b)
                    ),
                    severity: severity
                )
            }
            return Issue(
                netId: found.a.netId, netLabel: found.a.netLabel,
                kind: .channelClearance(
                    otherNetId: found.b.netId, otherNetLabel: found.b.netLabel,
                    layer: found.a.layer, wall: max(0, found.wall),
                    selfSegmentIndex: found.a.segmentIndex,
                    otherSegmentIndex: found.b.segmentIndex,
                    position: approachPoint(found.a.a, found.a.b, found.b.a, found.b.b)
                ),
                severity: severity
            )
        }
        // Dictionary order is arbitrary; sort so recomputes are stable.
        return issues.sorted { $0.summary < $1.summary }
    }

    private static func collectRouteEdges(
        in doc: CircuitDocument,
        parentRouteCount: Int = .max,
        labelOverrides: [UUID: String]? = nil
    ) -> [ChannelEdge] {
        let labels = Dictionary(uniqueKeysWithValues: doc.logic.nets.map { ($0.id, $0.label) })
        var out: [ChannelEdge] = []
        for (routeIndex, route) in doc.physical.routes.enumerated() {
            let label = labelOverrides?[route.netId] ?? labels[route.netId] ?? "?"
            let fromSubpart = routeIndex >= parentRouteCount
            for (segIdx, seg) in route.segments.enumerated() {
                let pts = seg.waypoints
                guard pts.count >= 2 else { continue }
                for i in 0..<(pts.count - 1) {
                    out.append(ChannelEdge(
                        netId: route.netId, netLabel: label,
                        segmentIndex: segIdx, layer: seg.layer,
                        a: pts[i].position, b: pts[i + 1].position,
                        fromSubpart: fromSubpart
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
    private static func portBoreClearanceIssues(
        in doc: CircuitDocument,
        labels labelOverrides: [UUID: String]? = nil
    ) -> [Issue] {
        let m = doc.manufacturing
        let threshold = wallScanThreshold(m)
        guard threshold > 0 else { return [] }
        let bores = collectPortBores(in: doc)
        guard !bores.isEmpty else { return [] }
        let channelRadius = m.channelDiameter / 2
        let routeEdges = collectRouteEdges(in: doc, labelOverrides: labelOverrides)

        struct PairKey: Hashable { let port: UUID; let other: UUID; let layer: Layer }
        var issues: [Issue] = []

        // Outlet vs foreign routed channels. Worst wall per pair so the
        // reported severity is the pair's true one.
        var bestChannel: [PairKey: (bore: PortBore, edge: ChannelEdge, wall: Double)] = [:]
        for bore in bores {
            for edge in routeEdges where edge.layer == bore.layer && edge.netId != bore.netId {
                let wall = segmentDistance(bore.a, bore.b, edge.a, edge.b) - (bore.radius + channelRadius)
                guard wall < threshold else { continue }
                let key = PairKey(port: bore.componentId, other: edge.netId, layer: bore.layer)
                if let current = bestChannel[key], current.wall <= wall { continue }
                bestChannel[key] = (bore, edge, wall)
            }
        }
        for found in bestChannel.values {
            issues.append(Issue(
                netId: found.bore.netId, netLabel: found.bore.netLabel,
                kind: .portBoreClearance(
                    portComponentId: found.bore.componentId, portLabel: found.bore.label,
                    neighbor: .channel, otherComponentId: nil,
                    otherNetId: found.edge.netId, otherLabel: found.edge.netLabel,
                    layer: found.bore.layer, wall: max(0, found.wall),
                    position: approachPoint(found.bore.a, found.bore.b, found.edge.a, found.edge.b)
                ),
                severity: wallSeverity(found.wall, m)
            ))
        }

        // Outlet vs other outlets.
        var bestOutlet: [PairKey: (a: PortBore, b: PortBore, wall: Double)] = [:]
        for i in 0..<bores.count {
            for j in (i + 1)..<bores.count {
                let a = bores[i], b = bores[j]
                guard a.netId != b.netId, a.layer == b.layer else { continue }
                let wall = segmentDistance(a.a, a.b, b.a, b.b) - (a.radius + b.radius)
                guard wall < threshold else { continue }
                let key = PairKey(port: a.componentId, other: b.netId, layer: a.layer)
                if let current = bestOutlet[key], current.wall <= wall { continue }
                bestOutlet[key] = (a, b, wall)
            }
        }
        for found in bestOutlet.values {
            issues.append(Issue(
                netId: found.a.netId, netLabel: found.a.netLabel,
                kind: .portBoreClearance(
                    portComponentId: found.a.componentId, portLabel: found.a.label,
                    neighbor: .outlet, otherComponentId: found.b.componentId,
                    otherNetId: found.b.netId, otherLabel: found.b.label,
                    layer: found.a.layer, wall: max(0, found.wall),
                    position: approachPoint(found.a.a, found.a.b, found.b.a, found.b.b)
                ),
                severity: wallSeverity(found.wall, m)
            ))
        }
        return issues.sorted { $0.summary < $1.summary }
    }

    // MARK: - Testing-point clearance

    /// Each testing point's vertical bore (tapped channel midline → plate
    /// outer face) checked against foreign-net channels and other testing
    /// points on the same plate. Like `portBoreClearanceIssues`, the bore is
    /// pure 3D geometry invisible on the 2D layer. Unlike the flat port
    /// outlet, the bore is vertical and spans a Z band `[zLo, zHi]`, so the
    /// channel check is depth-aware (a depth-0 bore can pass the Z level of a
    /// laterally-near depth-1 foreign channel on its way out) — it mirrors the
    /// depth-aware thin-wall bore branch. One issue per test point (its worst
    /// offence) keeps the sidebar from spamming.
    private static func testPointClearanceIssues(
        in doc: CircuitDocument,
        labels labelOverrides: [UUID: String]? = nil
    ) -> [Issue] {
        let m = doc.manufacturing
        let threshold = wallScanThreshold(m)
        guard threshold > 0, !doc.physical.testPoints.isEmpty else { return [] }
        let boreR = m.portBoreDiameter / 2
        let channelR = m.channelDiameter / 2
        let labels = Dictionary(uniqueKeysWithValues: doc.logic.nets.map { ($0.id, $0.label) })

        // Per-plate outer-face Z, matching `PlateBuilder.build`.
        let topInnerZ = m.siliconeThickness / 2
        let bottomInnerZ = -m.siliconeThickness / 2
        let topOuterZ = topInnerZ + m.plateThickness(forLayerCount: doc.physical.topLayers)
        let bottomOuterZ = bottomInnerZ - m.plateThickness(forLayerCount: doc.physical.bottomLayers)

        struct TPBore { let tp: TestPoint; let pos: Point; let zLo: Double; let zHi: Double }
        var bores: [TPBore] = []
        for tp in doc.physical.testPoints {
            guard let pos = doc.physical.testPointWorld(tp) else { continue }
            let midZ = m.midZ(for: doc.physical.testPointLayer(tp))
            let outerZ = tp.plate == .top ? topOuterZ : bottomOuterZ
            bores.append(TPBore(tp: tp, pos: pos,
                                zLo: min(midZ, outerZ), zHi: max(midZ, outerZ)))
        }
        guard !bores.isEmpty else { return [] }

        let edges = collectRouteEdges(in: doc, labelOverrides: labelOverrides)
        var issues: [Issue] = []

        // 1. Against foreign-net channels (Z-band aware).
        for bore in bores {
            var worst: (wall: Double, layer: Layer, otherLabel: String)?
            for edge in edges where edge.layer.plate == bore.tp.plate {
                if edge.netId == bore.tp.netId { continue }   // its own tapped net
                let dxy = pointSegmentDistance(bore.pos, edge.a, edge.b)
                let cz = m.midZ(for: edge.layer)
                let dz = max(0, max(bore.zLo - cz, cz - bore.zHi))
                let centre = (dxy * dxy + dz * dz).squareRoot()
                let wall = centre - channelR - boreR
                if wall < threshold, worst == nil || wall < worst!.wall {
                    worst = (wall, edge.layer, edge.netLabel)
                }
            }
            if let w = worst {
                issues.append(Issue(
                    netId: bore.tp.netId, netLabel: labels[bore.tp.netId] ?? "?",
                    kind: .testPointClearance(
                        testPointId: bore.tp.id, testPointName: bore.tp.name,
                        neighbor: .channel, otherLabel: w.otherLabel,
                        layer: w.layer, wall: max(0, w.wall), position: bore.pos
                    ),
                    severity: wallSeverity(w.wall, m)
                ))
            }
        }

        // 2. Against other testing points on the same plate. Both bore out to
        // the same outer face, so the wall is just the XY gap minus both radii.
        for i in 0..<bores.count {
            for j in (i + 1)..<bores.count {
                let a = bores[i], b = bores[j]
                guard a.tp.plate == b.tp.plate else { continue }
                let wall = hypot(a.pos.x - b.pos.x, a.pos.y - b.pos.y) - 2 * boreR
                guard wall < threshold else { continue }
                issues.append(Issue(
                    netId: a.tp.netId, netLabel: labels[a.tp.netId] ?? "?",
                    kind: .testPointClearance(
                        testPointId: a.tp.id, testPointName: a.tp.name,
                        neighbor: .testPoint, otherLabel: b.tp.name,
                        layer: doc.physical.testPointLayer(a.tp),
                        wall: max(0, wall), position: a.pos
                    ),
                    severity: wallSeverity(wall, m)
                ))
            }
        }
        return issues
    }

    // MARK: - Pin drift

    /// Flags transistor / LED pin bores that sit measurably off-centre from
    /// the channel that plumbs them — the "constants drift" case. Bore and
    /// channel still fuse while the drift stays under a channel radius — the
    /// board works, the aperture just shrinks — so nothing else reports it:
    /// the wall checks treat the pair as same-net (correctly), and
    /// connectivity is a logical check that never measures the gap.
    ///
    /// Covers both scopes, because both print the same defect:
    ///
    /// - Hoisted sub-part pins. The flatten computes pin positions with the
    ///   PARENT's constants (that is what `PlateBuilder` drills), but the
    ///   sub-part's internal routes were drawn against the library file's
    ///   own; when the two disagree (`padsOffset`, usually) every affected
    ///   pad prints with its drop bore offset from the channel end.
    /// - This document's own top-level pins. A pads-constant edited after
    ///   routing strands the file's own route endpoints off the bores this
    ///   same file drills — so the standalone print carries the defect too,
    ///   and used to validate clean because the check only ever looked at
    ///   hoisted components (found 2026-08-01: XOR.vpcb and AND 2.vpcb both
    ///   reported 0 issues standalone while their pads sat 0.14 mm off
    ///   their channels, visible only one level up in Half Adder 2.vpcb).
    ///
    /// Same closest-route attribution as `collectBores`' `plumbedNet`, and
    /// the same known approximation: a pin whose net is unrouted can
    /// misattribute to a foreign channel passing within the merge radius —
    /// that geometry is already flagged by the wall checks.
    /// Warning severity: drifted pads print and work, they're just not what
    /// the designer drew. One issue per (component, pin).
    private static func pinDriftIssues(
        in doc: CircuitDocument,
        parentRouteCount: Int,
        labels labelOverrides: [UUID: String]? = nil
    ) -> [Issue] {
        let m = doc.manufacturing
        let channelRadius = m.channelDiameter / 2
        /// Offsets below this are grid-snap / float noise, not drift.
        let noiseFloor = 0.05
        let edges = collectRouteEdges(in: doc, parentRouteCount: parentRouteCount,
                                      labelOverrides: labelOverrides)
        guard !edges.isEmpty else { return [] }

        var issues: [Issue] = []
        for placement in doc.physical.placements {
            guard let comp = doc.logic.components.first(where: { $0.id == placement.componentId }),
                  comp.kind == .transistor || comp.kind == .led
            else { continue }
            let fp = comp.footprint(m, snapshots: doc.librarySnapshots)
            for pin in fp.pins {
                let pinLayer = placement.resolvedLayer(of: pin, on: comp)
                let world = placement.worldPosition(of: pin)
                var closest = Double.greatestFiniteMagnitude
                var plumbed: ChannelEdge?
                for e in edges where e.layer.plate == pinLayer.plate {
                    let d = pointSegmentDistance(world, e.a, e.b)
                    if d < closest { closest = d; plumbed = e }
                }
                // Beyond a channel radius nothing plumbs this pin — that's
                // the wall checks' / connectivity's territory, not drift.
                guard let channel = plumbed, closest > noiseFloor, closest < channelRadius
                else { continue }
                issues.append(Issue(
                    netId: channel.netId, netLabel: channel.netLabel,
                    kind: .subpartPinDrift(
                        componentLabel: comp.label, pinKey: pin.key,
                        drift: closest, layer: pinLayer, position: world
                    ),
                    severity: .warning
                ))
            }
        }
        return issues.sorted { $0.summary < $1.summary }
    }

    // MARK: - Sealed print fragments

    /// Flags nets whose *printed* channel network splits into pieces the
    /// board can never join. The physical-volume decomposition applies the
    /// same connectivity the plates print with (`PlateBuilder`'s waypoint
    /// extension, bore-overlap healing up to one channel diameter, via
    /// pairing, resistor serpentines); this pass groups its cavities per
    /// net, joins a net's top/bottom cavities through cross-silicone bridge
    /// pairs, and reports every remaining fragment that has no external
    /// opening (port / vent / source / connector bore, testing point).
    ///
    /// This is the check `checkNet`'s union-find cannot do: its pin-snap
    /// tolerance is a dimple radius (2.5 mm+), wide enough to forgive a
    /// route that dead-ends short of a sub-part boundary pin — but the
    /// print only heals gaps up to one channel diameter, and a flattened
    /// board drops boundary pins entirely, so nothing extends the channel
    /// and the bore prints sealed (the Incrementor 4bit n16/n24 case: two
    /// vent taps orphaned 2 mm from their manifold, every check green).
    /// Fragments that do open to the outside are the tube-mated pattern
    /// (connector-joined assemblies) and stay exempt; fully unrouted nets
    /// are `noRouteDrawn`'s territory and stay quiet here.
    private static func sealedCavityIssues(in document: CircuitDocument) -> [Issue] {
        // The *simulation* flatten, not the CAD one `check` already holds:
        // physicalVolumes walks `logic.nets` for pin bores, and only the
        // simulation flatten rebuilds the netlist for hoisted internals
        // (the CAD flatten keeps the parent's nets, whose pins reference
        // the dropped sub-part placements). Net labels come pre-prefixed
        // ("U1.U2.n3") on the flattened nets themselves.
        let flat = document.flattenedForSimulation().document
        let labels = Dictionary(flat.logic.nets.map { ($0.id, $0.label) },
                                uniquingKeysWith: { a, _ in a })
        let routedNets = Set(flat.physical.routes.map(\.netId))
        guard !routedNets.isEmpty else { return [] }
        let volumes = physicalVolumes(flat)
        guard volumes.count > 1 else { return [] }
        let eps = 0.05

        // Union cavities joined by a cross-silicone bridge: a through-hole
        // present at the same XY on both plates mates when assembled.
        var parent = Array(0..<volumes.count)
        func find(_ x: Int) -> Int {
            var c = x
            while parent[c] != c { parent[c] = parent[parent[c]]; c = parent[c] }
            return c
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        let bridges: [(vol: Int, pos: Point)] = volumes.indices.flatMap { i in
            volumes[i].holes.filter(\.isBridge).map { (i, $0.pos) }
        }
        for i in 0..<bridges.count {
            for j in (i + 1)..<bridges.count
            where volumes[bridges[i].vol].plate != volumes[bridges[j].vol].plate {
                if abs(bridges[i].pos.x - bridges[j].pos.x) < eps,
                   abs(bridges[i].pos.y - bridges[j].pos.y) < eps {
                    union(bridges[i].vol, bridges[j].vol)
                }
            }
        }

        // A cavity the bench (or a mating tube) can reach from outside the
        // plate. Every edge-bore feature name contains "edge"; a testing
        // point bores out to the plate face.
        func isExternal(_ v: Volume) -> Bool {
            !v.testPoints.isEmpty || v.holes.contains { $0.feature.contains("edge") }
        }

        var volsByNet: [UUID: Set<Int>] = [:]
        for i in volumes.indices {
            for n in volumes[i].nets where routedNets.contains(n) {
                volsByNet[n, default: []].insert(i)
            }
        }

        var issues: [Issue] = []
        var reported: Set<String> = []   // fragment ids — resistor-merged fragments carry several nets
        for (netId, vols) in volsByNet {
            var pieces: [Int: [Int]] = [:]
            for i in vols { pieces[find(i), default: []].append(i) }
            guard pieces.count > 1 else { continue }
            func external(_ piece: [Int]) -> Bool { piece.contains { isExternal(volumes[$0]) } }
            func holeCount(_ piece: [Int]) -> Int { piece.reduce(0) { $0 + volumes[$1].holes.count } }
            // Reference piece — an externally reachable one if any, else the
            // biggest: the "rest of the net" the fragments are cut off from.
            let ranked = pieces.values.sorted {
                (external($0) ? 1 : 0, holeCount($0)) > (external($1) ? 1 : 0, holeCount($1))
            }
            for piece in ranked.dropFirst() where !external(piece) {
                let fragmentId = piece.map { volumes[$0].id }.sorted().joined(separator: "+")
                guard reported.insert(fragmentId).inserted else { continue }
                let holes = piece.flatMap { volumes[$0].holes }
                guard let first = holes.first else { continue }
                issues.append(Issue(
                    netId: netId, netLabel: labels[netId] ?? "?",
                    kind: .sealedCavity(
                        refs: holes.map(\.ref), layer: first.layer, position: first.pos)
                ))
            }
        }
        return issues.sorted { $0.summary < $1.summary }
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
    ///
    /// `flat`/`labels` are the shared flatten computed once in `check` (this
    /// used to flatten internally; the minimiser calls `check` per trial, so
    /// the flatten is shared across every flattened check now).
    private static func crossNetMergeIssues(
        flat: CircuitDocument, labels: [UUID: String]
    ) -> [Issue] {
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

    /// Middle of the thin wall itself: the midpoint of the two segments'
    /// closest pair of points. Crossing segments return the intersection.
    /// This is where the canvas ping / marker lands, so it must sit exactly
    /// where the gap is narrowest — the old midpoint-of-midpoints landed
    /// half a segment away on long parallel runs and read as random.
    /// Only computed for pairs already below the wall threshold, so the
    /// extra endpoint projections cost nothing in the common no-issue case.
    private static func approachPoint(
        _ a: Point, _ b: Point, _ c: Point, _ d: Point
    ) -> Point {
        if segmentsIntersect(a, b, c, d) {
            // Line-line solve; the guard above proves a proper crossing, so
            // the denominator is non-zero.
            let r = Point(x: b.x - a.x, y: b.y - a.y)
            let s = Point(x: d.x - c.x, y: d.y - c.y)
            let denom = r.x * s.y - r.y * s.x
            let t = ((c.x - a.x) * s.y - (c.y - a.y) * s.x) / denom
            return Point(x: a.x + t * r.x, y: a.y + t * r.y)
        }
        // Closest pair among endpoint-to-opposite-segment projections — the
        // non-crossing minimum is always anchored at one of the four ends.
        var bestDist = Double.infinity
        var bestPair = (a, c)
        for (p, s1, s2) in [(a, c, d), (b, c, d), (c, a, b), (d, a, b)] {
            let q = closestPointOnSegment(p, s1, s2)
            let dist = (p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y)
            if dist < bestDist {
                bestDist = dist
                bestPair = (p, q)
            }
        }
        return Point(x: (bestPair.0.x + bestPair.1.x) / 2,
                     y: (bestPair.0.y + bestPair.1.y) / 2)
    }

    private static func closestPointOnSegment(_ p: Point, _ a: Point, _ b: Point) -> Point {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return a }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq))
        return Point(x: a.x + t * dx, y: a.y + t * dy)
    }

    // MARK: - Wall thickness

    /// Walks every channel polyline edge and flags places where the printed
    /// wall between the channel and a nearby feature (outer face, another
    /// channel, a vertical bore) is thinner than `minWallThickness` (error)
    /// or `preferredWallThickness` (warning).
    /// Shares the wall-thickness model with `channelClearance` (which owns the
    /// same-layer different-net channel case) but covers what that one can't:
    /// the outer face, vertical bores, and cross-layer channel pairs whose 3D
    /// wall is thin. `crossNetMerge` is the orthogonal electrical check —
    /// centre distance under `channelDiameter`, i.e. the tubes actually overlap.
    ///
    /// Runs on the flattened doc (`check` passes it in): findings among the
    /// document's own geometry report as `.thinWall` exactly as before;
    /// findings with a sub-part-internal side report as `.subpartWall`. The
    /// board outline always comes from `parent` — a sub-part's own outline
    /// isn't a printed face inside the parent, the parent's is.
    ///
    /// Dedup is per `(netId, segmentIndex, neighbor)` at the *worst* wall, so
    /// a long parallel run reports one issue per neighbor category rather
    /// than per edge — and a mixed warning/error run reports the error.
    private static func thinWallIssues(
        in doc: CircuitDocument,
        parent: CircuitDocument? = nil,
        parentRouteCount: Int = .max,
        parentComponentIds: Set<UUID>? = nil,
        labels labelOverrides: [UUID: String]? = nil
    ) -> [Issue] {
        let m = doc.manufacturing
        let threshold = wallScanThreshold(m)
        guard threshold > 0 else { return [] }

        let channelRadius = m.channelDiameter / 2
        let edges = collectRouteEdges(in: doc, parentRouteCount: parentRouteCount,
                                      labelOverrides: labelOverrides)
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
        // loop below into a no-op without a second code path. The flag (and
        // the outline itself) is read off the parent doc, never a hoisted
        // sub-part: a sub-part's own edge anchors mean nothing against the
        // parent's outline.
        let outlineDoc = parent ?? doc
        let outlineEdges = (outlineDoc.skipEdgeWallDRC ?? false)
            ? [] : outerBoundaryEdges(in: outlineDoc)

        // Bores carry the world-Z band they occupy so the wall check can tell
        // a real same-depth conflict from a buried channel passing safely over
        // a shallow feature one layer away, and their net id so the check can
        // skip same-net pairs (a transistor's drop bore sitting near another
        // segment of its own net would otherwise produce a spurious thin-wall
        // warning — the two volumes are supposed to fuse, not stay separated).
        // Port / vent / vacuum-source bores enter horizontally and
        // intentionally meet the outer face — `collectBores` never emits
        // them, so they can't produce false positives at every port.
        let bores = collectBores(in: doc, parentComponentIds: parentComponentIds,
                                 parentRouteCount: parentRouteCount,
                                 labelOverrides: labelOverrides)

        struct ReportKey: Hashable {
            let netId: UUID
            /// Classic findings keep the per-segment granularity; sub-part
            /// findings use -1 — their segments aren't user-visible, so two
            /// rows differing only by segment would read as duplicates.
            let segmentIndex: Int
            let neighbor: ThinWallNeighbor
            /// Sub-part findings dedup on who the other side is instead.
            let otherNetId: UUID?
            let otherLabel: String?
            let layer: Layer?
        }
        struct Candidate {
            let edge: ChannelEdge
            let neighbor: ThinWallNeighbor
            let otherNetId: UUID?
            let otherLabel: String?
            let otherFromSubpart: Bool
            let gap: Double
            let position: Point
        }
        var best: [ReportKey: Candidate] = [:]

        func record(edge: ChannelEdge, neighbor: ThinWallNeighbor,
                    otherNetId: UUID? = nil, otherLabel: String? = nil,
                    otherFromSubpart: Bool = false,
                    gap: Double, position: Point) {
            let subpartFinding = edge.fromSubpart || otherFromSubpart
            let key = subpartFinding
                ? ReportKey(netId: edge.netId, segmentIndex: -1, neighbor: neighbor,
                            otherNetId: otherNetId, otherLabel: otherLabel,
                            layer: edge.layer)
                : ReportKey(netId: edge.netId, segmentIndex: edge.segmentIndex,
                            neighbor: neighbor, otherNetId: nil, otherLabel: nil,
                            layer: nil)
            if let current = best[key], current.gap <= gap { return }
            best[key] = Candidate(
                edge: edge, neighbor: neighbor,
                otherNetId: otherNetId, otherLabel: otherLabel,
                otherFromSubpart: otherFromSubpart,
                gap: gap, position: position
            )
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
                    record(edge: edge, neighbor: .outerFace, gap: wall, position: pos)
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
                    record(edge: edge, neighbor: .channel,
                           otherNetId: other.netId, otherLabel: other.netLabel,
                           otherFromSubpart: other.fromSubpart,
                           gap: wall, position: pos)
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
                    record(edge: edge, neighbor: .bore,
                           otherNetId: bore.netId, otherLabel: bore.label,
                           otherFromSubpart: bore.fromSubpart,
                           gap: wall, position: bore.position)
                }
            }
        }

        let issues = best.values.map { c -> Issue in
            let severity = wallSeverity(c.gap, m)
            if c.edge.fromSubpart || c.otherFromSubpart {
                return Issue(
                    netId: c.edge.netId, netLabel: c.edge.netLabel,
                    kind: .subpartWall(
                        neighbor: c.neighbor, otherNetId: c.otherNetId,
                        otherLabel: c.otherLabel, layer: c.edge.layer,
                        wall: max(0, c.gap), position: c.position
                    ),
                    severity: severity
                )
            }
            return Issue(
                netId: c.edge.netId, netLabel: c.edge.netLabel,
                kind: .thinWall(
                    neighbor: c.neighbor,
                    layer: c.edge.layer,
                    gap: max(0, c.gap),
                    segmentIndex: c.edge.segmentIndex,
                    position: c.position
                ),
                severity: severity
            )
        }
        // Dictionary order is arbitrary; sort so recomputes are stable.
        return issues.sorted { $0.summary < $1.summary }
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
                  !(comp.connectorDebugPorts ?? false),   // debug mode adds no protrusion
                  let anchor = placement.edgeAnchor
            else { continue }
            let n = max(1, comp.connectorPinCount ?? 1)
            let endCapY = ComponentKind.connectorScrewLocalYs(
                pinCount: n,
                screwCount: comp.connectorScrewCount ?? ComponentKind.connectorMinScrewCount
            ).last ?? 0
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
