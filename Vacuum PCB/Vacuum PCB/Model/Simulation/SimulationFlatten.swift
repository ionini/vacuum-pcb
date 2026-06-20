import Foundation

/// Netlist-preserving subpart flattening for the simulator.
///
/// The CAD flattener `CircuitDocument.flattened()` deliberately drops nets
/// across subpart boundaries — `PlateBuilder` only needs placements and
/// routes, and regenerating internal net IDs simplifies that pipeline.
///
/// The simulator, on the other hand, *is* the netlist: every node in the
/// pneumatic network is a net, every edge is a component connecting two
/// nets. Subpart internals have to feed into the same node graph as the
/// parent's components, so we need a flattener that unifies nets across
/// each subpart boundary.
///
/// The merge rule: every library file declares its boundary as ordinary
/// `port` / `vacuumSource` / `atmVent` components. Each library-internal
/// net touching one of those boundary components corresponds to a parent
/// net touching the matching subpart-instance boundary pin (whose pin key
/// is the boundary component's UUID string — that's how the parent
/// references the library's pins). We union the two on every match, then
/// drop the boundary components and the parent's now-meaningless subpart
/// pin refs from the result.
extension CircuitDocument {

    /// Like `flattened()` but the returned document's nets remain valid
    /// and span every primitive contributed by every subpart instance.
    /// Subparts disappear; only primitives remain. Reference cycles are
    /// broken at first re-entry, same as `flattened()`.
    ///
    /// `netIdRemap` maps every net id present in *this* (unflattened) level's
    /// `logic.nets` to the id of the surviving canonical net it was fused
    /// into — identity for nets that weren't merged. Callers that render the
    /// unflattened topology (the Simulate schematic) need this to look up a
    /// merged net's pressure, which is keyed by the canonical id only.
    func flattenedForSimulation() -> (document: CircuitDocument, netIdRemap: [UUID: UUID]) {
        flattenedForSimulation(visiting: [])
    }

    /// Recursive worker. `visiting` is the chain of library filenames
    /// currently being expanded; re-entering one of those is treated as a
    /// reference cycle and the offending placement is silently skipped.
    func flattenedForSimulation(visiting: Set<String>) -> (document: CircuitDocument, netIdRemap: [UUID: UUID]) {
        // Seed buckets with everything in the parent doc that *isn't* a
        // subpart instance.
        var components: [Component] = self.logic.components.filter { $0.kind != .subpart }
        var placements: [Placement] = self.physical.placements.filter { p in
            self.logic.components.first(where: { $0.id == p.componentId })?.kind != .subpart
        }
        // Routes get re-emitted at the end with their netIds canonicalised
        // so any subpart-merge that fused this route's net into another is
        // reflected in the output.
        var routes: [Route] = self.physical.routes

        var netsById: [UUID: Net] = [:]
        var canonicalForOldId: [UUID: UUID] = [:]
        // Maps (parent subpart instance id, connector component id inside
        // the subpart's flattened library doc) → the freshly-minted UUID
        // for that connector in this flat output. Used at the end of the
        // flatten to resolve `Mating` endpoints whose `.subpartSocket`
        // case references the original library connector id.
        var socketIds: [SimulationSocketKey: UUID] = [:]

        func canonical(_ id: UUID) -> UUID {
            var c = id
            while let next = canonicalForOldId[c], next != c { c = next }
            // Path compression keeps subsequent lookups O(1) when the same
            // net id is referenced many times (large flat circuits).
            var i = id
            while let next = canonicalForOldId[i], next != c {
                canonicalForOldId[i] = c
                i = next
            }
            return c
        }

        func addNet(_ net: Net) {
            netsById[net.id] = net
            canonicalForOldId[net.id] = net.id
        }

        @discardableResult
        func mergeNets(_ aId: UUID, _ bId: UUID) -> UUID {
            let ra = canonical(aId), rb = canonical(bId)
            if ra == rb { return ra }
            guard let na = netsById[ra], let nb = netsById[rb] else { return rb }
            // Keep the second id as canonical. Concatenate pins; dedup
            // later if needed (pin equality is by (componentId, key) so
            // two identical refs are harmless either way).
            netsById[rb] = Net(
                id: rb,
                label: nb.label.isEmpty ? na.label : nb.label,
                pins: nb.pins + na.pins
            )
            netsById.removeValue(forKey: ra)
            canonicalForOldId[ra] = rb
            return rb
        }

        for net in self.logic.nets { addNet(net) }

        // Walk every subpart placement at this level and inline its
        // (already-flattened) library contents.
        for subpartPlacement in self.physical.placements {
            guard let parentComp = self.logic.components.first(where: { $0.id == subpartPlacement.componentId }),
                  parentComp.kind == .subpart,
                  let filename = parentComp.partRef,
                  !visiting.contains(filename),
                  let part = parentComp.resolvedPart(snapshots: self.librarySnapshots)
            else { continue }

            let child = part.document.flattenedForSimulation(visiting: visiting.union([filename])).document

            // Build an id remap for every non-boundary child component
            // and identify the boundary components (they get dropped from
            // the output — they're connection markers, not real features).
            let boundaryKinds: Set<ComponentKind> = [.port, .vacuumSource, .atmVent]
            var idMap: [UUID: UUID] = [:]
            var boundaryComponentIds = Set<UUID>()
            for c in child.logic.components {
                if boundaryKinds.contains(c.kind) {
                    boundaryComponentIds.insert(c.id)
                } else {
                    idMap[c.id] = UUID()
                }
            }

            // Pose transform from child-local to parent-world. Mirrors the
            // existing CAD flattener exactly so geometry lands in the same
            // place either pipeline takes.
            let outline = part.document.physical.boardOutline
            let ox = outline.minX, oy = outline.minY
            let r = subpartPlacement.rotation.radians
            let cosR = cos(r), sinR = sin(r)
            func toWorld(_ p: Point) -> Point {
                let dx = p.x - ox, dy = p.y - oy
                return Point(
                    x: subpartPlacement.position.x + dx * cosR - dy * sinR,
                    y: subpartPlacement.position.y + dx * sinR + dy * cosR
                )
            }

            // Inline non-boundary placements.
            for placement in child.physical.placements {
                if boundaryComponentIds.contains(placement.componentId) { continue }
                guard let newId = idMap[placement.componentId] else { continue }
                placements.append(Placement(
                    componentId: newId,
                    position: toWorld(placement.position),
                    rotation: composeRotationForSimFlatten(placement.rotation, then: subpartPlacement.rotation),
                    layer: placement.layer,
                    depth: placement.depth
                ))
            }

            // Inline non-boundary components, prefixing labels so the
            // sidebar lists "U1.Q1" instead of two ambiguous "Q1" rows.
            // Connector fields (`connectorPinCount`, `connectorRole`)
            // must be propagated too — without them an inlined 4-pin
            // connector reads as 1 pin to `PneumaticNetwork.build`
            // (it does `max(1, nil ?? 1)`), which collapses every
            // daughterboard's connector to a single phantom toggle.
            for c in child.logic.components {
                if boundaryComponentIds.contains(c.id) { continue }
                guard let newId = idMap[c.id] else { continue }
                components.append(Component(
                    id: newId,
                    kind: c.kind,
                    label: "\(parentComp.label).\(c.label)",
                    resistorSize: c.resistorSize,
                    portDirection: c.portDirection,
                    connectorPinCount: c.connectorPinCount,
                    connectorScrewCount: c.connectorScrewCount,
                    connectorRole: c.connectorRole,
                    connectorSignal: c.connectorSignal,
                    connectorPinNames: c.connectorPinNames
                ))
                if c.kind == .connector {
                    socketIds[SimulationSocketKey(
                        subpartId: subpartPlacement.componentId,
                        connectorId: c.id
                    )] = newId
                }
            }

            // Rewrite child nets through the id map, then for each child
            // net that touches a boundary component, union it with the
            // parent net touching the matching subpart-instance pin.
            var childNetIdToNew: [UUID: UUID] = [:]
            for childNet in child.logic.nets {
                var rewrittenPins: [PinRef] = []
                var boundaryRefs: [UUID] = []
                for pin in childNet.pins {
                    if boundaryComponentIds.contains(pin.componentId) {
                        boundaryRefs.append(pin.componentId)
                    } else if let newId = idMap[pin.componentId] {
                        rewrittenPins.append(PinRef(componentId: newId, pinKey: pin.pinKey))
                    }
                    // Pins whose component is in neither set can't happen
                    // for a valid library, but if they do we silently drop
                    // them so the simulator gets a well-formed netlist.
                }
                let newNetId = UUID()
                addNet(Net(
                    id: newNetId,
                    label: "\(parentComp.label).\(childNet.label)",
                    pins: rewrittenPins
                ))
                childNetIdToNew[childNet.id] = newNetId

                // Union with each parent net that touches one of this
                // child net's boundary pins. The parent's pin key for a
                // subpart boundary is the boundary component's UUID
                // string (PartsLibrary publishes pins keyed that way).
                for boundaryCompId in boundaryRefs {
                    let parentPinRef = PinRef(
                        componentId: subpartPlacement.componentId,
                        pinKey: boundaryCompId.uuidString
                    )
                    if let hit = netsById.first(where: { $0.value.pins.contains(parentPinRef) }) {
                        mergeNets(newNetId, hit.key)
                    }
                }
            }

            // Inline child routes, mapping their net id through the new
            // child→parent net id table. World-position transform mirrors
            // placement geometry.
            for route in child.physical.routes {
                guard let mappedNetId = childNetIdToNew[route.netId] else { continue }
                let newSegments = route.segments.map { seg -> Segment in
                    let newWaypoints = seg.waypoints.map {
                        Waypoint(position: toWorld($0.position), kind: $0.kind)
                    }
                    return Segment(waypoints: newWaypoints, layer: seg.layer)
                }
                routes.append(Route(netId: mappedNetId, segments: newSegments))
            }
        }

        // Strip every pin that still references a subpart placement from
        // the result — those were only there to anchor the boundary, and
        // the subpart placement isn't in the output. Then canonicalise
        // every route's netId so a merged route lands on the right net.
        let subpartInstanceIds: Set<UUID> = Set(
            self.logic.components.filter { $0.kind == .subpart }.map(\.id)
        )
        for id in netsById.keys {
            netsById[id]?.pins.removeAll { subpartInstanceIds.contains($0.componentId) }
        }

        // Every connector pin must appear in some net or
        // `PneumaticNetwork.build` won't expose it as an input / probe —
        // its `pinToNet` lookup silently skips dangling pins. Library-
        // internal connectors typically have one wired pin (the one the
        // user routed inside the library) and the rest dangling; those
        // dangling pins are still real physical terminals once the part
        // is in an assembly. Add a fresh single-pin net for any
        // un-netted connector pin so the simulator sees every pin.
        let pinToNet = PneumaticNetwork.pinToNetMap(CircuitDocument(
            manufacturing: self.manufacturing,
            logic: LogicGraph(components: components,
                              nets: Array(netsById.values)),
            schematic: self.schematic,
            physical: PhysicalLayout(placements: placements,
                                     routes: routes,
                                     boardOutline: self.physical.boardOutline,
                                     topLayers: self.physical.topLayers,
                                     bottomLayers: self.physical.bottomLayers)
        ))
        for c in components where c.kind == .connector {
            let n = max(1, c.connectorPinCount ?? 1)
            for i in 1...n {
                let ref = PinRef(componentId: c.id, pinKey: "\(i)")
                if pinToNet[ref] != nil { continue }
                let netId = UUID()
                addNet(Net(id: netId, label: "\(c.label).\(i)", pins: [ref]))
            }
        }

        // Apply matings. Each Mating contributes N pin-pair net merges
        // (pin i of A ≡ pin i of B for all i ∈ 1...N). Endpoints whose
        // socket can't be resolved (subpart placement gone, deeper-than-
        // one-level recursion) are skipped silently — DRC surfaces those
        // as user-visible issues against the unflattened doc. Mated
        // connectors are collected so we can drop their `Component`
        // entries below: their pins are now internal interconnects, not
        // user-facing terminals, so `PneumaticNetwork.build` must not
        // expose them as Input/Probe rows in the simulator sidebar.
        var matedConnectorIds = Set<UUID>()
        for mating in self.logic.matings {
            let aId = Self.resolveSimEndpoint(mating.a, socketIds: socketIds)
            let bId = Self.resolveSimEndpoint(mating.b, socketIds: socketIds)
            guard let aId, let bId, aId != bId else { continue }
            guard let aComp = components.first(where: { $0.id == aId }),
                  let bComp = components.first(where: { $0.id == bId }),
                  aComp.kind == .connector, bComp.kind == .connector
            else { continue }
            let n = min(aComp.connectorPinCount ?? 0, bComp.connectorPinCount ?? 0)
            guard n > 0 else { continue }
            for i in 1...n {
                let a = PinRef(componentId: aId, pinKey: "\(i)")
                let b = PinRef(componentId: bId, pinKey: "\(i)")
                // Find current net for each pin (after the dangling-pin
                // pass every pin is guaranteed to belong to some net).
                guard let netA = netsById.first(where: { $0.value.pins.contains(a) })?.key,
                      let netB = netsById.first(where: { $0.value.pins.contains(b) })?.key
                else { continue }
                mergeNets(netA, netB)
            }
            matedConnectorIds.insert(aId)
            matedConnectorIds.insert(bId)
        }
        if !matedConnectorIds.isEmpty {
            components.removeAll { matedConnectorIds.contains($0.id) }
            placements.removeAll { matedConnectorIds.contains($0.componentId) }
        }

        let finalNets: [Net] = netsById.values.map { net in
            Net(id: net.id, label: net.label, pins: net.pins)
        }
        let finalRoutes: [Route] = routes.map { route in
            Route(netId: canonical(route.netId), segments: route.segments)
        }

        let logic = LogicGraph(components: components, nets: finalNets)
        var physical = self.physical
        physical.placements = placements
        physical.routes = finalRoutes

        // Resolve every net id this level ever held to its final canonical id
        // so callers rendering the unflattened topology can find the pressure
        // of a net that mating/subpart merges fused away.
        var netIdRemap: [UUID: UUID] = [:]
        for id in Array(canonicalForOldId.keys) {
            netIdRemap[id] = canonical(id)
        }

        return (CircuitDocument(
            manufacturing: self.manufacturing,
            logic: logic,
            schematic: self.schematic,
            physical: physical
        ), netIdRemap)
    }
}

extension CircuitDocument {
    fileprivate static func resolveSimEndpoint(
        _ endpoint: ConnectorEndpoint,
        socketIds: [SimulationSocketKey: UUID]
    ) -> UUID? {
        switch endpoint {
        case .topLevel(let id):
            return id
        case .subpartSocket(let sid, let cid):
            return socketIds[SimulationSocketKey(subpartId: sid, connectorId: cid)]
        }
    }
}

/// Two-tuple key used to track which connector inside which subpart
/// placement got which freshly-minted UUID during simulator flatten.
/// Mirrors the CAD flatten's `SocketKey` but lives here so the two
/// pipelines don't share private types.
fileprivate struct SimulationSocketKey: Hashable {
    let subpartId: UUID
    let connectorId: UUID
}

/// Local copy of `CircuitDocument.composeRotation(_:then:)` — the original
/// is fileprivate and only adds two same-step indices anyway.
private func composeRotationForSimFlatten(_ first: Rotation, then second: Rotation) -> Rotation {
    let order: [Rotation] = [.r0, .r90, .r180, .r270]
    let i = (order.firstIndex(of: first) ?? 0)
          + (order.firstIndex(of: second) ?? 0)
    return order[i % 4]
}
