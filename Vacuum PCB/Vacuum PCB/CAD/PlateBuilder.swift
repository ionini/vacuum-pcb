import Foundation
import Euclid

/// Produces the top and bottom plate solids for a CircuitDocument.
/// Coordinate system: model XY → world XY (mm). Z is the plate-normal axis.
/// Silicone occupies z ∈ [-siliconeThickness/2, +siliconeThickness/2].
/// Top plate sits above the silicone, bottom plate below.
///
/// Channels run as round bores through the *midline* of each plate (not as open
/// grooves on the silicone face). Transistor pins (gate / source / drain) connect
/// the channel network to the silicone face via vertical drop bores. Edge ports
/// enter horizontally at the midline.
enum PlateBuilder {

    struct Output {
        let topPlate: Mesh
        let bottomPlate: Mesh
        /// Union of every channel / drop bore / dimple / serpentine / port bore
        /// that was subtracted from the top plate. Used by the 3D preview's
        /// "features only" mode to show the routing solids without the plate.
        let topFeatures: Mesh
        let bottomFeatures: Mesh
        /// Flat printed sheet sitting at z=0 (the silicone gap), matching the
        /// board outline and punched through at every cross-silicone via and
        /// screw shaft. Used at assembly as a 1:1 cutting template for the
        /// silicone sheet. Empty when `stencilThickness` is 0.
        let stencil: Mesh
        /// Open-top/open-bottom rounded-rect frame ("cookie cutter") the
        /// silicone sheet is cast in — printed `siliconeThickness` tall and
        /// surrounding the board outline by `castingMargin + moldWallThickness`.
        /// Empty when `moldWallThickness` is ≤ 0. See `Mold` for the layout.
        let moldFrame: Mesh
        /// Volume of silicone to pour into the casting frame, in mm³ — the
        /// pour cavity's footprint (board outline + `.bottomExtend` connector
        /// protrusions, each grown by `castingMargin`) × `siliconeThickness`.
        /// Measured off the cavity solid so overlapping connector tabs are
        /// counted once. 0 when the frame is disabled.
        let siliconeVolumeMM3: Double
    }

    static func build(_ doc: CircuitDocument) -> Output {
        // Subpart instances are expanded into their library file's
        // primitives before any CSG runs — the plate sees the flattened
        // design, identical to what the user would get if they'd hand-
        // duplicated every gate / resistor / route from XOR.vpcb into the
        // parent doc.
        let doc = doc.flattened()
        let m = doc.manufacturing
        let outline = doc.physical.boardOutline

        let topInnerZ = m.siliconeThickness / 2                  // top plate's silicone-facing face
        let bottomInnerZ = -m.siliconeThickness / 2              // bottom plate's silicone-facing face

        // Per-plate thicknesses scale with the number of channel layers in
        // each plate. With layerCount == 1 they reduce to today's
        // `plateThickness` value, so single-layer designs print bit-identical
        // geometry.
        let topThickness = m.plateThickness(forLayerCount: doc.physical.topLayers)
        let bottomThickness = m.plateThickness(forLayerCount: doc.physical.bottomLayers)

        let top = plateBase(outline: outline, thickness: topThickness,
                            innerZ: topInnerZ, side: .top,
                            edgeChamfer: m.plateCornerFillet)
        let bottom = plateBase(outline: outline, thickness: bottomThickness,
                               innerZ: bottomInnerZ, side: .bottom,
                               edgeChamfer: m.plateCornerFillet)

        // Depth-0 midline z's, used by drop bores / dimples / port bores
        // (all of which anchor to the silicone-facing channel layer).
        let topMidZ = m.midZ(for: Layer(plate: .top, depth: 0))
        let bottomMidZ = m.midZ(for: Layer(plate: .bottom, depth: 0))

        var topCutters: [Mesh] = []
        var bottomCutters: [Mesh] = []
        // Additive material that needs to be unioned onto the plate before
        // the cutters are subtracted — currently only the volcano dome
        // around protruding screw heads / nuts, but kept generic.
        var topAdditions: [Mesh] = []
        var bottomAdditions: [Mesh] = []
        // Connector protrusions — intentionally extend past `boardOutline`,
        // so they bypass `buildPlateCSG`'s outline clipper (which exists to
        // keep volcano domes from overhanging the board edge).
        var topUnclippedAdditions: [Mesh] = []
        var bottomUnclippedAdditions: [Mesh] = []
        // Silicone (stencil) extensions added by `.bottomExtend` connectors
        // — the silicone gasket extends with the bottom plate into the
        // protrusion area so the mating side's top plate can clamp against
        // it. Empty when no `.bottomExtend` connector is present.
        var stencilExtensions: [Mesh] = []
        // World-space outlines of those same `.bottomExtend` protrusions — the
        // casting frame must wrap the silicone where it extends past the board
        // edge, so the mold cavity grows to follow each one.
        var moldExtensionOutlines: [Rect] = []

        // Resolve current pin world positions per plate before channels run,
        // so the channel-build loop can extend any segment whose endpoint
        // waypoint was drawn at an old pin location (the user shifted
        // `padsOffset` afterwards). Without this the horizontal route stays
        // where it was while the drop bore has moved outward.
        let componentsById = Dictionary(uniqueKeysWithValues: doc.logic.components.map { ($0.id, $0) })
        let pinsPerLayer = collectPinPositions(doc: doc, m: m, componentsById: componentsById)
        let pinSnapTol = m.dimpleDiameter / 2 + 0.5

        // 1. Channels — round bores swept along Manhattan polylines at the
        // layer's midline. Layer carries both the plate and the depth, so
        // multi-layer routing falls out automatically.
        for route in doc.physical.routes {
            for segment in route.segments {
                let midZ = m.midZ(for: segment.layer)
                let positions = extendedWaypointPositions(
                    for: segment,
                    pinsOnLayer: pinsPerLayer[segment.layer]?[route.netId] ?? [],
                    tolerance: pinSnapTol
                )
                let channel = channelMesh(
                    waypoints: positions,
                    radius: m.channelDiameter / 2,
                    midZ: midZ,
                    flatBottom: m.flatBottomChannels,
                    flipFloor: segment.layer.plate == .bottom
                )
                appendCutter(channel, plate: segment.layer.plate,
                             top: &topCutters, bottom: &bottomCutters)
            }
        }

        // 2. Component features. All components anchor at depth 0; geometry
        // unchanged from single-layer.

        for placement in doc.physical.placements {
            guard let component = componentsById[placement.componentId] else { continue }
            switch component.kind {
            case .transistor:
                let dimple = dimpleMesh(
                    at: placement.position, layer: placement.layer, m: m,
                    topInnerZ: topInnerZ, bottomInnerZ: bottomInnerZ
                )
                appendCutter(dimple, plate: placement.layer,
                             top: &topCutters, bottom: &bottomCutters)

                // Source/drain pad cavities on the opposite plate's silicone
                // face. Both pads come out of a single sphere with the middle
                // strip carved out; the drop bores land inside the cavity.
                let pads = padsCavityMesh(
                    placement: placement, m: m,
                    topInnerZ: topInnerZ, bottomInnerZ: bottomInnerZ
                )
                appendCutter(pads, plate: placement.layer.opposite,
                             top: &topCutters, bottom: &bottomCutters)

                // Drop bore at each transistor pin, connecting channel midline to the
                // silicone face on whichever plate the pin sits on.
                let footprint = component.footprint(m)
                for pin in footprint.pins {
                    let pinPlate = placement.resolvedPlate(of: pin)
                    let pinWorld = placement.worldPosition(of: pin)
                    let drop = dropBoreMesh(
                        at: pinWorld, onPlate: pinPlate, radius: m.channelDiameter / 2,
                        topInnerZ: topInnerZ, bottomInnerZ: bottomInnerZ,
                        topMidZ: topMidZ, bottomMidZ: bottomMidZ
                    )
                    appendCutter(drop, plate: pinPlate,
                                 top: &topCutters, bottom: &bottomCutters)
                }

            case .resistor:
                let serpentine = resistorSerpentineMesh(
                    placement: placement, component: component, m: m,
                    topMidZ: topMidZ, bottomMidZ: bottomMidZ
                )
                appendCutter(serpentine, plate: placement.layer,
                             top: &topCutters, bottom: &bottomCutters)

            case .port, .vacuumSource, .atmVent:
                let bore = portBoreMesh(
                    placement: placement, outline: outline, m: m,
                    topMidZ: topMidZ, bottomMidZ: bottomMidZ
                )
                appendCutter(bore, plate: placement.layer,
                             top: &topCutters, bottom: &bottomCutters)

            case .subpart:
                // Subpart internals aren't flattened into the printed STL
                // in v1 — the user sees them in the physical canvas only.
                // 3D preview and export ignore subpart placements.
                break

            case .led:
                // Dimple on the placement layer — same dome construction as
                // a transistor's gate, but with the LED's own diameter and
                // raw depth (sphere centre `ledDimpleDepth` mm into the
                // plate body, *not* derived from diameter).
                let ledDimple = ledDimpleMesh(
                    at: placement.position, layer: placement.layer, m: m,
                    topInnerZ: topInnerZ, bottomInnerZ: bottomInnerZ
                )
                appendCutter(ledDimple, plate: placement.layer,
                             top: &topCutters, bottom: &bottomCutters)

                // Viewing hole — cylinder through the *opposite* plate, 1 mm
                // wider than the dimple, so the deflected silicone is
                // visible from outside. Overshoots the outer face by the
                // worst-case volcano-dome height so a screw placed near the
                // LED doesn't cap the hole on its way out of the plate.
                let oppositePlate = placement.layer.opposite
                let oppositeThickness = oppositePlate == .top ? topThickness : bottomThickness
                let viewHole = ledViewHoleMesh(
                    at: placement.position, onPlate: oppositePlate,
                    diameter: m.ledDimpleDiameter + 1.0,
                    topInnerZ: topInnerZ, bottomInnerZ: bottomInnerZ,
                    topThickness: topThickness, bottomThickness: bottomThickness,
                    outerOvershoot: m.screwProtrusion > 0
                        ? m.screwProtrusion + 0.5
                        : 0
                )
                appendCutter(viewHole, plate: oppositePlate,
                             top: &topCutters, bottom: &bottomCutters)
                _ = oppositeThickness

                // Drop bore connecting the (single) fluid pin's channel
                // midline to the dimple chamber on the placement layer.
                let ledFootprint = component.footprint(m)
                for pin in ledFootprint.pins {
                    let pinPlate = placement.resolvedPlate(of: pin)
                    let pinWorld = placement.worldPosition(of: pin)
                    let drop = dropBoreMesh(
                        at: pinWorld, onPlate: pinPlate, radius: m.channelDiameter / 2,
                        topInnerZ: topInnerZ, bottomInnerZ: bottomInnerZ,
                        topMidZ: topMidZ, bottomMidZ: bottomMidZ
                    )
                    appendCutter(drop, plate: pinPlate,
                                 top: &topCutters, bottom: &bottomCutters)
                }

            case .screw:
                // `placement.layer` tracks which plate hosts the screw
                // head (the nut sinks into the opposite plate). F flips
                // it, swapping head and nut sides without moving the
                // through-hole.
                let screw = ScrewGeometry.meshes(
                    at: placement.position, rotation: placement.rotation,
                    topInnerZ: topInnerZ, topThickness: topThickness,
                    bottomInnerZ: bottomInnerZ, bottomThickness: bottomThickness,
                    protrusion: m.screwProtrusion,
                    domeBaseDiameter: m.screwDomeBaseDiameter,
                    headDepth: m.screwHeadDepth,
                    nutDepth: m.screwNutDepth,
                    headSide: placement.layer
                )
                topCutters.append(contentsOf: screw.topCutters)
                bottomCutters.append(contentsOf: screw.bottomCutters)
                topAdditions.append(contentsOf: screw.topAdditions)
                bottomAdditions.append(contentsOf: screw.bottomAdditions)

            case .connector:
                let role = component.connectorRole ?? .bottomExtend
                let fp = component.footprint(m)
                // Protrusion slab in world coordinates. The footprint's
                // exclusionRect sits in local space at r0 (origin at the
                // inner edge midpoint, extending along local +X). Rotated
                // and translated into world; built as a rounded-rect prism
                // (3 mm corner fillet on the OUTER edges) extended inward
                // by `cornerRadius` so the rounded inner corners get
                // buried inside the board body when unioned, leaving the
                // junction with the board sharp.
                let connectorCornerRadius: Double = 3.0
                let halfExt = fp.exclusionRect.size.width / 2
                let halfRow = fp.exclusionRect.size.height / 2
                // Centre the slab in local space at the new midpoint
                // between (inward extension `-cornerRadius`) and
                // (outwardExtent). After rotation the corresponding world
                // point lands at the rotated-and-translated centroid.
                let localCentre = Point(x: (2 * halfExt - connectorCornerRadius) / 2, y: 0)
                let worldCentre = placement.worldPosition(of: FootprintPin(
                    key: "_centroid", offset: localCentre, relativeLayer: .same
                ))
                // Slab dimensions in local space then mapped onto world
                // axes (rotations are r0/r90/r180/r270, always axis-aligned).
                let localSlabX = 2 * halfExt + connectorCornerRadius
                let localSlabY = 2 * halfRow
                let isHorizontal = placement.rotation == .r0 || placement.rotation == .r180
                let slabWidth = isHorizontal ? localSlabX : localSlabY
                let slabHeight = isHorizontal ? localSlabY : localSlabX
                let protrusionOutline = Rect(
                    origin: Point(x: worldCentre.x - slabWidth / 2,
                                  y: worldCentre.y - slabHeight / 2),
                    size: Size(width: slabWidth, height: slabHeight)
                )

                let plateSide: Plate
                let plateInnerZ: Double
                let plateThicknessHere: Double
                switch role {
                case .bottomExtend:
                    plateSide = .bottom
                    plateInnerZ = bottomInnerZ
                    plateThicknessHere = bottomThickness
                case .topExtend:
                    plateSide = .top
                    plateInnerZ = topInnerZ
                    plateThicknessHere = topThickness
                }
                let bodySlab = plateBase(
                    outline: protrusionOutline,
                    thickness: plateThicknessHere,
                    innerZ: plateInnerZ,
                    side: plateSide,
                    edgeChamfer: connectorCornerRadius
                )
                switch role {
                case .bottomExtend:
                    bottomUnclippedAdditions.append(bodySlab)
                    // Silicone extends with the bottom plate. Build a
                    // matching slab at z=0 spanning the *stencil* thickness
                    // (NOT siliconeThickness — the stencil is a printed
                    // cutting template that's typically thicker than the
                    // gasket it shapes). Same rounded outline so the
                    // stencil's protrusion matches the bottom plate's.
                    let stencilSlab = plateBase(
                        outline: protrusionOutline,
                        thickness: m.stencilThickness,
                        innerZ: -m.stencilThickness / 2,
                        side: .top,
                        edgeChamfer: connectorCornerRadius
                    )
                    stencilExtensions.append(stencilSlab)
                    moldExtensionOutlines.append(protrusionOutline)
                case .topExtend:
                    topUnclippedAdditions.append(bodySlab)
                }

                // Tube cutters at each pin. The bore connects the route
                // channel midline inside the plate to the mating face —
                // it does NOT extend to the plate's outer face (that would
                // open a hole on the external side of the assembly and
                // leak straight to atmosphere). For `.bottomExtend` the
                // tube also continues through the extended silicone so
                // the channel reaches the mating top face.
                let tubeRadius = m.channelDiameter / 2
                let eps = 0.05
                for pin in fp.pins {
                    let pinWorld = placement.worldPosition(of: pin)
                    let zLo: Double
                    let zHi: Double
                    switch role {
                    case .bottomExtend:
                        zLo = bottomMidZ - eps           // channel midline inside the bottom plate
                        zHi = topInnerZ + eps            // top face of extended silicone (mating face)
                    case .topExtend:
                        zLo = topInnerZ - eps            // bottom face of top plate (mating face)
                        zHi = topMidZ + eps              // channel midline inside the top plate
                    }
                    let length = zHi - zLo
                    let cz = (zLo + zHi) / 2
                    let tube = Mesh.cylinder(radius: tubeRadius, height: length, slices: 16)
                        .rotated(by: Euclid.Rotation.pitch(.halfPi))
                        .translated(by: Vector(pinWorld.x, pinWorld.y, cz))
                    switch role {
                    case .bottomExtend: bottomCutters.append(tube)
                    case .topExtend:    topCutters.append(tube)
                    }
                }

                // End-cap screws. Each connector half only contributes
                // ONE side of the bolted joint: `.topExtend` carves the
                // countersink head cavity on the top face of the top-
                // plate extension; `.bottomExtend` carves the hex-nut
                // pocket on the bottom face of the bottom-plate extension.
                // The mating partner (a separate `.vpcb` design) carves
                // the other half. Through-bore spans the full assembly
                // either way so the M2 shaft slips through. `protrusion`
                // is 0 — heads and nuts sit flush with the outer face.
                let endCapY = ComponentKind.connectorEndCapLocalY(pinCount: component.connectorPinCount ?? 1)
                for ySign in [-1.0, 1.0] {
                    let endLocal = Point(x: halfExt, y: ySign * endCapY)
                    let endWorld = placement.worldPosition(of: FootprintPin(
                        key: "_endcap", offset: endLocal, relativeLayer: .same
                    ))
                    let screw = ScrewGeometry.meshes(
                        at: endWorld, rotation: placement.rotation,
                        topInnerZ: topInnerZ, topThickness: topThickness,
                        bottomInnerZ: bottomInnerZ, bottomThickness: bottomThickness,
                        protrusion: 0,
                        domeBaseDiameter: m.screwDomeBaseDiameter,
                        headDepth: m.screwHeadDepth,
                        nutDepth: m.screwNutDepth,
                        headSide: .top
                    )
                    switch role {
                    case .bottomExtend:
                        // Bottom half — keeps only the nut-pocket side
                        // (hex prism + through-bore). The head cavity
                        // lives on the mating top half.
                        bottomCutters.append(contentsOf: screw.bottomCutters)
                    case .topExtend:
                        // Top half — keeps only the countersink side
                        // (head cavity + through-bore). The nut pocket
                        // lives on the mating bottom half.
                        topCutters.append(contentsOf: screw.topCutters)
                    }
                }
            }
        }

        // 3. Vias — vertical bores spanning min(twin.z) … max(twin.z) at the
        // marked XY. With multi-layer plates, twins can sit on the same plate
        // at different depths (a vertical tube *inside* one plate, no
        // silicone crossing), or on opposite plates (today's behaviour).
        // Dedup by position because each via is represented twice in the
        // document (once at each end of its twin pair).
        struct ViaGroup { var position: Point; var layers: Set<Layer> }
        var viaGroups: [ViaGroup] = []
        for route in doc.physical.routes {
            for segment in route.segments {
                for wp in segment.waypoints where wp.kind == .via {
                    if let idx = viaGroups.firstIndex(where: { approxEqualXY($0.position, wp.position) }) {
                        viaGroups[idx].layers.insert(segment.layer)
                    } else {
                        viaGroups.append(ViaGroup(position: wp.position, layers: [segment.layer]))
                    }
                }
            }
        }
        for group in viaGroups {
            guard group.layers.count >= 2 else { continue }
            let zs = group.layers.map { m.midZ(for: $0) }
            let zLo = zs.min()!, zHi = zs.max()!
            let cutter = viaCutterMesh(at: group.position, radius: m.channelDiameter / 2,
                                       zLo: zLo, zHi: zHi)
            // A via cuts whichever plate(s) it actually passes through. If
            // every layer in the group is on the same plate, only that plate
            // gets the cutter (no need to drill the opposite slab).
            let plates = Set(group.layers.map { $0.plate })
            if plates.contains(.top) { topCutters.append(cutter) }
            if plates.contains(.bottom) { bottomCutters.append(cutter) }
        }

        // Top and bottom plates are independent after this point — the
        // additions union, cutters union, plate subtraction, and feature
        // clip all run per-plate, so we dispatch both sides across two
        // cores. Euclid itself parallelises internally per CSG call; this
        // adds an outer layer of parallelism so the second core isn't idle
        // while the first plate runs a `.subtracting`.
        // Volcano domes push the head / hex cavity cylinders past the plate
        // slab by `screwProtrusion`. Widen the preview clip's outer
        // overshoot to match so the cavities show all the way through the
        // dome.
        let screwOvershoot = m.screwProtrusion > 0
            ? m.screwProtrusion + 0.5
            : 0
        let clipOvershoot = max(1, screwOvershoot)

        var topOut: (plate: Mesh, preview: Mesh) = (top, .empty)
        var bottomOut: (plate: Mesh, preview: Mesh) = (bottom, .empty)
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            switch index {
            case 0:
                topOut = buildPlateCSG(
                    base: top, additions: topAdditions,
                    unclippedAdditions: topUnclippedAdditions,
                    cutters: topCutters,
                    outline: outline, innerZ: topInnerZ,
                    thickness: topThickness, side: .top,
                    cornerRadius: m.plateCornerFillet,
                    additionOvershoot: screwOvershoot,
                    previewOvershoot: clipOvershoot
                )
            default:
                bottomOut = buildPlateCSG(
                    base: bottom, additions: bottomAdditions,
                    unclippedAdditions: bottomUnclippedAdditions,
                    cutters: bottomCutters,
                    outline: outline, innerZ: bottomInnerZ,
                    thickness: bottomThickness, side: .bottom,
                    cornerRadius: m.plateCornerFillet,
                    additionOvershoot: screwOvershoot,
                    previewOvershoot: clipOvershoot
                )
            }
        }

        // Stencil: a flat sheet centred on the silicone gap with the same
        // outline as the plates, punched through at every cross-silicone via
        // and screw shaft. CSG is small (~one slab minus a handful of short
        // cylinders) so it runs sequentially rather than fanning out — the
        // two-plate parallelism above already saturates the typical Euclid
        // pass that costs anything.
        var stencilCutters: [(position: Point, diameter: Double)] = []
        // Oversize the via holes in the cutting template: the cut silicone
        // plug contracts once the plates squeeze it, so the seated plug needs
        // a wider hole to still clear the via. Padding adds to the diameter.
        let stencilViaDiameter = m.channelDiameter + m.stencilViaPadding
        for position in doc.physical.crossSiliconeViaPositions() {
            stencilCutters.append((position, stencilViaDiameter))
        }
        for placement in doc.physical.placements {
            guard let component = componentsById[placement.componentId],
                  component.kind == .screw
            else { continue }
            stencilCutters.append((placement.position, ScrewGeometry.throughDiameter))
        }
        // `.bottomExtend` connector tubes and end-caps pass through the
        // extended silicone region — punch the same holes in the stencil so
        // the cutting template lines up with the printed protrusion.
        for placement in doc.physical.placements {
            guard let component = componentsById[placement.componentId],
                  component.kind == .connector,
                  (component.connectorRole ?? .bottomExtend) == .bottomExtend
            else { continue }
            let fp = component.footprint(m)
            for pin in fp.pins {
                let pinWorld = placement.worldPosition(of: pin)
                stencilCutters.append((pinWorld, m.channelDiameter))
            }
            // End-cap screw clearance holes — same layout as the bottom
            // plate's end-cap bores so the stencil punches match. Punches
            // only the through-bore (not the nut pocket — that's in the
            // bottom plate proper, not in the silicone gasket).
            let halfExt = fp.exclusionRect.size.width / 2
            let endCapY = ComponentKind.connectorEndCapLocalY(pinCount: component.connectorPinCount ?? 1)
            for ySign in [-1.0, 1.0] {
                let endLocal = Point(x: halfExt, y: ySign * endCapY)
                let endWorld = placement.worldPosition(of: FootprintPin(
                    key: "_endcap", offset: endLocal, relativeLayer: .same
                ))
                stencilCutters.append((endWorld, ScrewGeometry.throughDiameter))
            }
        }
        let stencil = buildStencil(
            outline: outline, thickness: m.stencilThickness,
            cornerRadius: m.plateCornerFillet,
            extensions: stencilExtensions,
            cutters: stencilCutters
        )

        // Silicone casting frame — a ring around the full silicone footprint
        // (board outline + any `.bottomExtend` connector protrusions), printed
        // as its own body for pouring the sheet. Independent of the stencil's
        // holes (the frame is a plain rim) so it's cheap to build alongside it.
        let mold = buildMold(outline: outline, m: m, extensions: moldExtensionOutlines)

        // `makeWatertight()` is intentionally NOT called here. Euclid's BSP
        // CSG can leave hairline cracks where curved surfaces meet flat
        // ones; slicers refuse to print non-manifold STLs, so the export
        // sites (`STLExportDocument`, the Bambu Studio path) watertight on
        // demand. SceneKit doesn't care about manifoldness, so the preview
        // skips the stitching pass — it's one of the heavier Euclid
        // operations and the preview is the hot path.
        return Output(
            topPlate: topOut.plate, bottomPlate: bottomOut.plate,
            topFeatures: topOut.preview, bottomFeatures: bottomOut.preview,
            stencil: stencil,
            moldFrame: mold.frame,
            siliconeVolumeMM3: mold.volumeMM3
        )
    }

    // MARK: - Stencil

    /// Builds a thin sheet centred on z=0, matching the board outline (with
    /// the plates' corner fillet so all three bodies stack cleanly in the
    /// preview), then subtracts a cylinder at every cutter XY. Returns the
    /// empty mesh when thickness ≤ 0 — the user has disabled stencil export.
    private static func buildStencil(
        outline: Rect, thickness: Double, cornerRadius: Double,
        extensions: [Mesh] = [],
        cutters: [(position: Point, diameter: Double)]
    ) -> Mesh {
        guard thickness > 0 else { return .empty }
        let half = thickness / 2
        // `plateBase(side: .top, innerZ: -half, thickness: thickness)` puts
        // the lower face at z = -half and the upper face at z = +half, which
        // is exactly the centred-on-zero slab we want. The polygon winding
        // it produces is correct for an exterior solid.
        var slab = plateBase(
            outline: outline, thickness: thickness,
            innerZ: -half, side: .top, edgeChamfer: cornerRadius
        )
        // `.bottomExtend` connectors carry the silicone into the protrusion
        // area — each extension is a slab in the silicone gap that unions
        // onto the base stencil so the cutting template includes it.
        if !extensions.isEmpty {
            slab = slab.union(Mesh.union(extensions))
        }
        guard !cutters.isEmpty else { return slab }
        let eps = 0.1
        let cylHeight = thickness + 2 * eps
        let cutterMeshes = cutters.map { c in
            Mesh.cylinder(radius: c.diameter / 2, height: cylHeight, slices: 24)
                .rotated(by: Euclid.Rotation.pitch(.halfPi))
                .translated(by: Vector(c.position.x, c.position.y, 0))
        }
        return slab.subtracting(Mesh.union(cutterMeshes))
    }

    // MARK: - Mold (silicone casting frame)

    /// Builds the silicone casting frame and the pour volume.
    ///
    /// The frame is a rounded ring printed `siliconeThickness` tall and centred
    /// on the silicone gap (z=0). Its footprint is the board outline plus every
    /// `.bottomExtend` connector protrusion (`extensions`) — the silhouette the
    /// silicone actually fills. Each footprint is grown by `castingMargin` for
    /// the pour cavity and by `castingMargin + moldWallThickness` for the outer
    /// edge; CSG-unioning the per-footprint slabs merges connector tabs into one
    /// contiguous rim, then the cavity is subtracted to hollow it out.
    ///
    /// `volumeMM3` is measured off the cavity solid (`signedVolume`) so the
    /// silicone in overlapping board/connector regions is counted once. Returns
    /// `(.empty, 0)` when the frame is disabled (`moldWallThickness` ≤ 0) or the
    /// sheet has no thickness.
    private static func buildMold(
        outline: Rect, m: ManufacturingConstants, extensions: [Rect]
    ) -> (frame: Mesh, volumeMM3: Double) {
        guard m.siliconeThickness > 0, m.moldWallThickness > 0 else { return (.empty, 0) }
        let margin = max(0, m.castingMargin)
        let wall = m.moldWallThickness
        let t = m.siliconeThickness
        let half = t / 2
        let eps = 0.1

        // Footprints making up the silicone silhouette. The board carries the
        // plates' corner fillet; connector tabs start square (the outward offset
        // rounds them on its own).
        let footprints: [(rect: Rect, fillet: Double)] =
            [(outline, m.plateCornerFillet)] + extensions.map { ($0, 0.0) }

        func slabs(inset: Double, thickness: Double, innerZ: Double) -> [Mesh] {
            footprints.map { fp in
                let inflated = Mold.inflate(fp.rect, by: inset)
                let r = Mold.cornerRadius(for: inflated, baseFillet: fp.fillet, inset: inset)
                return plateBase(outline: inflated, thickness: thickness,
                                 innerZ: innerZ, side: .top, edgeChamfer: r)
            }
        }

        let outerSolid = Mesh.union(slabs(inset: margin + wall, thickness: t, innerZ: -half))
        // Cavity cutter overshoots in Z so subtracting it doesn't leave coplanar
        // top/bottom faces (the eps trick `buildStencil` uses for via holes).
        let cavityCutter = Mesh.union(
            slabs(inset: margin, thickness: t + 2 * eps, innerZ: -half - eps))
        let frame = outerSolid.subtracting(cavityCutter)

        // The cutter is the pour cavity grown by eps top and bottom; since it's
        // prismatic, scaling its volume by t/(t+2·eps) recovers the true
        // sheet-height pour amount without a second union.
        let volume = abs(cavityCutter.signedVolume) * t / (t + 2 * eps)
        return (frame, volume)
    }

    /// Per-plate CSG pipeline: union the additive domes onto the base
    /// slab, union the cutter list, subtract the cutter union from the
    /// plate, and clip the cutter union to the plate slab for the
    /// features-only preview. Runs on a single side so the two plates can
    /// be processed in parallel.
    private static func buildPlateCSG(
        base: Mesh, additions: [Mesh],
        unclippedAdditions: [Mesh] = [],
        cutters: [Mesh],
        outline: Rect, innerZ: Double, thickness: Double, side: Plate,
        cornerRadius: Double, additionOvershoot: Double,
        previewOvershoot: Double
    ) -> (plate: Mesh, preview: Mesh) {
        var plate = base
        if !additions.isEmpty {
            // Clip dome additions to the plate's XY outline so a screw near
            // the board edge doesn't grow a volcano that overhangs the
            // boundary. The clipper is the same rounded-rect prism as the
            // plate, extended in Z to cover the full dome height.
            let clipper = plateBase(
                outline: outline,
                thickness: thickness + max(0, additionOvershoot),
                innerZ: innerZ, side: side,
                edgeChamfer: cornerRadius
            )
            let clipped = Mesh.union(additions).intersection(clipper)
            plate = plate.union(clipped)
        }
        // Connector protrusions are intentionally outside the outline —
        // union without clipping so the slab extends past `boardOutline`.
        if !unclippedAdditions.isEmpty {
            plate = plate.union(Mesh.union(unclippedAdditions))
        }
        let featuresUnion = cutters.isEmpty ? Mesh.empty : Mesh.union(cutters)
        if !cutters.isEmpty {
            plate = plate.subtracting(featuresUnion)
        }
        let preview = clippedToPlateSlab(
            featuresUnion, outline: outline,
            innerZ: innerZ, thickness: thickness, side: side,
            outerOvershoot: previewOvershoot
        )
        return (plate, preview)
    }

    /// Intersects a features mesh with a fat cube covering the plate's z
    /// slab and outline (with a small XY margin so edge-port bores aren't
    /// trimmed). The intersection lives in the preview-only path; slivers
    /// from the CSG cut are harmless to SceneKit.
    private static func clippedToPlateSlab(
        _ mesh: Mesh, outline: Rect, innerZ: Double, thickness: Double, side: Plate,
        outerOvershoot: Double = 1
    ) -> Mesh {
        if mesh.isEmpty { return mesh }
        let xyMargin: Double = 5     // wider than port-bore overshoot

        let outerZ: Double
        let cubeCenterZ: Double
        let cubeHeight: Double
        switch side {
        case .top:
            outerZ = innerZ + thickness
            cubeCenterZ = (innerZ + outerZ + outerOvershoot) / 2
            cubeHeight = (outerZ + outerOvershoot) - innerZ
        case .bottom:
            outerZ = innerZ - thickness
            cubeCenterZ = (innerZ + outerZ - outerOvershoot) / 2
            cubeHeight = innerZ - (outerZ - outerOvershoot)
        }

        let cx = outline.origin.x + outline.size.width / 2
        let cy = outline.origin.y + outline.size.height / 2
        let cube = Mesh.cube(
            center: Vector(cx, cy, cubeCenterZ),
            size: Vector(
                outline.size.width + 2 * xyMargin,
                outline.size.height + 2 * xyMargin,
                cubeHeight
            )
        )
        return mesh.intersection(cube)
    }

    // MARK: - Plate base

    private static func plateBase(
        outline: Rect, thickness: Double, innerZ: Double, side: Plate,
        edgeChamfer: Double
    ) -> Mesh {
        // Clamp the corner fillet so a wild settings entry can't collapse
        // the plate to a degenerate shape — the radius can't exceed half
        // the plate's smallest in-plane dimension (else neighbouring arcs
        // would intersect at the centre).
        let maxClamp = min(outline.size.width / 2 * 0.99,
                           outline.size.height / 2 * 0.99)
        let r = max(0, min(edgeChamfer, maxClamp))

        let cx = outline.origin.x + outline.size.width / 2
        let cy = outline.origin.y + outline.size.height / 2

        if r <= 0 {
            // Sharp-cornered plain slab. Identical to legacy behaviour so
            // existing docs round-trip pixel-for-pixel.
            let cz = side == .top ? innerZ + thickness / 2
                                  : innerZ - thickness / 2
            return Mesh.cube(
                center: Vector(cx, cy, cz),
                size: Vector(outline.size.width, outline.size.height, thickness)
            )
        }
        return roundedCornerPlate(
            outline: outline, thickness: thickness,
            innerZ: innerZ, side: side, cornerRadius: r
        )
    }

    /// Builds a plate whose four vertical corner edges are rounded — the
    /// outline viewed from above is a rounded rectangle. The fillet runs the
    /// full plate height; both the silicone-facing face and the outer face
    /// share the same rounded-rect profile. Curved walls are approximated
    /// with `segmentsPerCorner` flat strips per quarter-arc.
    private static func roundedCornerPlate(
        outline: Rect, thickness: Double, innerZ: Double, side: Plate, cornerRadius r: Double
    ) -> Mesh {
        let segmentsPerCorner = 8

        let outerZ: Double
        switch side {
        case .top:    outerZ = innerZ + thickness
        case .bottom: outerZ = innerZ - thickness
        }

        // Rounded-rect outline, walked CCW (viewed from +Z). Each corner's
        // quarter-arc contributes `segmentsPerCorner + 1` points; adjacent
        // corners' endpoints sit on opposite ends of a straight edge, so
        // the straight runs along the rectangle's sides fall out implicitly
        // as polygon edges between successive corner-arc vertices.
        //
        // Per-corner parameters (centerX, centerY, startAngle); each arc
        // sweeps CCW by π/2 over the corner.
        //   BR: centre (maxX-r, minY+r), starts at -π/2 (south)
        //   TR: centre (maxX-r, maxY-r), starts at  0     (east)
        //   TL: centre (minX+r, maxY-r), starts at  π/2  (north)
        //   BL: centre (minX+r, minY+r), starts at  π    (west)
        let corners: [(cx: Double, cy: Double, start: Double)] = [
            (outline.maxX - r, outline.minY + r, -Double.pi / 2),
            (outline.maxX - r, outline.maxY - r, 0),
            (outline.minX + r, outline.maxY - r, Double.pi / 2),
            (outline.minX + r, outline.minY + r, Double.pi),
        ]
        var outlineXY: [(x: Double, y: Double)] = []
        for corner in corners {
            for i in 0...segmentsPerCorner {
                let t: Double = Double(i) / Double(segmentsPerCorner)
                let angle: Double = corner.start + t * Double.pi / 2
                let x: Double = corner.cx + r * cos(angle)
                let y: Double = corner.cy + r * sin(angle)
                outlineXY.append((x, y))
            }
        }

        let silicone = outlineXY.map { Vector($0.x, $0.y, innerZ) }
        let outer    = outlineXY.map { Vector($0.x, $0.y, outerZ) }
        let n = outlineXY.count

        // Helper: build a polygon from vertices, discarding nils so a
        // numerical fluke doesn't crash the whole build.
        func poly(_ pts: [Vector]) -> Polygon? {
            Polygon(pts.map { Vertex($0) })
        }

        var polygons: [Polygon] = []

        // Caps. Silicone face points away from the plate body (top plate's
        // silicone face is -Z, bottom plate's silicone face is +Z); outer
        // face points the opposite direction. Reverse winding accordingly.
        switch side {
        case .top:
            if let s = poly(Array(silicone.reversed())) { polygons.append(s) }
            if let o = poly(outer) { polygons.append(o) }
        case .bottom:
            if let s = poly(silicone) { polygons.append(s) }
            if let o = poly(Array(outer.reversed())) { polygons.append(o) }
        }

        // Side walls — one quad per pair of adjacent outline vertices.
        // Wind quads so the outward normal points away from the plate axis.
        for i in 0..<n {
            let j = (i + 1) % n
            let quad: [Vector]
            switch side {
            case .top:    quad = [silicone[i], silicone[j], outer[j], outer[i]]
            case .bottom: quad = [outer[i], outer[j], silicone[j], silicone[i]]
            }
            if let p = poly(quad) { polygons.append(p) }
        }

        return Mesh(polygons)
    }

    // MARK: - Pin-snap extension

    /// Per-layer, per-net map of pin positions the channel build is allowed
    /// to extend a segment endpoint to. Restricted to transistor source/drain
    /// pins — they're the only pins whose world position can drift after a
    /// route was drawn (the user nudges `padsOffset` and the pads move
    /// outward), so they're the only pins that need the snap.
    ///
    /// Keyed by `route.netId` within each layer so a segment can only snap to
    /// a pin on its own net. Without that filter a route end that happened to
    /// drift near a *foreign* transistor's a/b pin would silently bridge the
    /// two nets in the CAD output even when the 2D connectivity check sees
    /// them as separate.
    ///
    /// Resistor / port / vent pins are fixed in world coordinates the moment
    /// they were placed, and snapping to them is actively harmful: a via that
    /// lands equidistant from two nearby pins on the same layer (e.g. an
    /// XOR's R1.pin1 and R2.pin1 only 4 mm apart, both ~2.83 mm from a shared
    /// via) picks up a phantom waypoint and draws a triangle whose hypotenuse
    /// bridges the two pins. The asymmetry surfaces in CSG: the union keeps
    /// the two near-tangent tubes apart on one subpart copy and merges them
    /// on another, shorting the resistors on only one of two otherwise-
    /// identical subpart copies.
    ///
    /// Keyed by full `Layer` (plate + depth) — keying by plate alone would
    /// let a top-d0 segment snap to a transistor pin on top-d1.
    static func collectPinPositions(
        doc: CircuitDocument, m: ManufacturingConstants,
        componentsById: [UUID: Component]
    ) -> [Layer: [UUID: [Point]]] {
        var netByPin: [PinRef: UUID] = [:]
        for net in doc.logic.nets {
            for pinRef in net.pins {
                netByPin[pinRef] = net.id
            }
        }
        // The routed channel terminates at its pin (the pad anchor). The
        // channel↔pad fluid path is carried by the drop bore at the pin — which
        // lands inside the pad cavity by construction — plus the channel's end
        // sphere overlapping the pad lobe, so the horizontal channel never needs
        // to reach toward the gate.
        //
        // The sole exception is one CSG degeneracy. A channel arriving
        // perpendicular to the source-drain axis has its gate-side wall on the
        // plane `dist - channelRadius` from the gate (channel ending at the pin,
        // so `dist == padsOffset`). When the params land that wall exactly on the
        // pad lobe's flat face (`padsSeparation / 2` from the gate) the two
        // coplanar surfaces make Euclid's BSP union leave a hairline sliver — the
        // same family as the +0.005 sphere bump in `channelMesh`. That's the
        // case at the defaults, where `padsOffset == padsSeparation/2 +
        // channelDiameter/2`. We break it by nudging the endpoint toward the gate
        // so the cylinder pierces past the flat face — but ONLY when the wall
        // actually reaches the flat face: `dist <= tangentDist` (+ a small band
        // for near-tangent params). Away from that knife-edge — e.g. a narrower
        // `channelDiameter` leaves the wall comfortably clear of the flat face —
        // the channel ends exactly at the pin, with no inward overshoot eating
        // the pad-separation seal. `canOvershoot` still guards the narrow-lobe
        // case where the pierce could graze the opposite lobe's flat face.
        let channelRadius = m.channelDiameter / 2
        let safetyMargin = 0.2
        let mergeDistanceFromGate = m.padsSeparation / 2 + channelRadius - safetyMargin
        let canOvershoot = m.padsSeparation > 2 * safetyMargin
        // Pin→gate distance at which the channel wall is coplanar with the pad
        // flat face. Only pins whose wall sits within `tangencyBand` of it are
        // genuinely tangent and get the pierce; everything farther out (wall
        // clear of the flat face) terminates at the pin.
        let tangentDist = m.padsSeparation / 2 + channelRadius
        let tangencyBand = 0.1
        var out: [Layer: [UUID: [Point]]] = [:]
        for placement in doc.physical.placements {
            guard let component = componentsById[placement.componentId],
                  component.kind == .transistor
            else { continue }
            for pin in component.footprint(m).pins where pin.key == "a" || pin.key == "b" {
                let pinRef = PinRef(componentId: placement.componentId, pinKey: pin.key)
                guard let netId = netByPin[pinRef] else { continue }
                let layer = placement.resolvedLayer(of: pin, on: component)
                let pinWorld = placement.worldPosition(of: pin)
                let gateWorld = placement.position
                let dx = pinWorld.x - gateWorld.x
                let dy = pinWorld.y - gateWorld.y
                let dist = (dx * dx + dy * dy).squareRoot()
                let snapTarget: Point
                if canOvershoot, dist > mergeDistanceFromGate,
                   dist <= tangentDist + tangencyBand, dist > 0 {
                    let t = (dist - mergeDistanceFromGate) / dist
                    snapTarget = Point(x: pinWorld.x - dx * t, y: pinWorld.y - dy * t)
                } else {
                    snapTarget = pinWorld
                }
                out[layer, default: [:]][netId, default: []].append(snapTarget)
            }
        }
        return out
    }

    /// Returns the segment's waypoint positions, with the first and/or last
    /// extended to the nearest pin on the same `Layer` (plate + depth) when
    /// the stored endpoint sits within `tolerance` mm of one (and isn't
    /// already exactly on it). The extra entry adds one more sphere +
    /// cylinder at the pin so the channel reaches the drop bore.
    static func extendedWaypointPositions(
        for segment: Segment, pinsOnLayer: [Point], tolerance: Double
    ) -> [Point] {
        var positions = segment.waypoints.map(\.position)
        guard !pinsOnLayer.isEmpty, !positions.isEmpty else { return positions }
        let snapEps = 0.01

        if let pin = nearestPoint(to: positions[0], in: pinsOnLayer, maxDist: tolerance),
           hypot(pin.x - positions[0].x, pin.y - positions[0].y) > snapEps {
            positions.insert(pin, at: 0)
        }
        if positions.count >= 2,
           let last = positions.last,
           let pin = nearestPoint(to: last, in: pinsOnLayer, maxDist: tolerance),
           hypot(pin.x - last.x, pin.y - last.y) > snapEps {
            positions.append(pin)
        }
        return positions
    }

    private static func nearestPoint(
        to p: Point, in candidates: [Point], maxDist: Double
    ) -> Point? {
        var best: Point?
        var bestD = maxDist
        for q in candidates {
            let d = hypot(q.x - p.x, q.y - p.y)
            if d < bestD { bestD = d; best = q }
        }
        return best
    }

    // MARK: - Channels

    /// Builds a round-bore channel running through `midZ` along a Manhattan polyline.
    /// Each waypoint contributes a sphere joint; each segment contributes a cylinder
    /// laid along its axis. Spheres + cylinders fully overlap so the union is closed.
    ///
    /// Sphere radius is bumped a hair above `radius` so each cylinder's flat end-cap
    /// lands strictly inside its bracketing sphere instead of being coplanar with the
    /// sphere's equator. With equal radii the cap and equator are the same disk in
    /// the same plane, which is a degenerate case for Euclid's BSP union: it leaves
    /// duplicate internal faces that show up as count=4 non-manifold edges along the
    /// channel's tangent lines and make slicers reject the STL. The bump is well
    /// below print resolution so the printed bore diameter is still `radius * 2`.
    ///
    /// When `flatBottom` is set, one half of the bore is squared off into a
    /// flat-floored rectangle while the other half stays a semicircular arch (see
    /// `floorBox` / `junctionFloorCylinder`). This adds void volume in the floor
    /// corners without changing the channel envelope or the printable arched
    /// ceiling. `flipFloor` chooses which half is the floor: the arch must face the
    /// plate's outer face (the up side when printed dimples-down), so the top plate
    /// keeps the arch up and the bottom plate — printed flipped — mirrors it. The
    /// round cylinders + spheres are kept as-is so all branch/T junctions stay
    /// watertight; the floor pieces are simply unioned on.
    private static func channelMesh(
        waypoints: [Point], radius: Double, midZ: Double,
        flatBottom: Bool = false, flipFloor: Bool = false
    ) -> Mesh {
        guard waypoints.count >= 2 else { return Mesh.empty }

        let sphereRadius = radius + 0.005

        var parts: [Mesh] = []
        parts.reserveCapacity(2 * waypoints.count)

        // Spheres at each waypoint so junctions are watertight at any branching angle.
        for p in waypoints {
            parts.append(Mesh.sphere(radius: sphereRadius, slices: 16)
                .translated(by: Vector(p.x, p.y, midZ)))
        }

        // Cylinders between adjacent waypoints. Euclid's cylinder is Y-axis
        // aligned. Roll(α) rotates around Z; the convention here is such that
        // roll(π/2) sends a horizontal-segment cylinder along X (the original
        // Manhattan-only code relied on this). Generalising: α = π/2 − θ,
        // where θ = atan2(dy, dx) is the segment angle in XY. This puts the
        // cylinder's long axis exactly along the segment so the joint spheres
        // line up at any angle.
        for i in 0..<(waypoints.count - 1) {
            let a = waypoints[i]
            let b = waypoints[i + 1]
            let dx = b.x - a.x
            let dy = b.y - a.y
            let len = (dx * dx + dy * dy).squareRoot()
            guard len > 0 else { continue }

            let cx = (a.x + b.x) / 2
            let cy = (a.y + b.y) / 2
            let theta = atan2(dy, dx)
            let cyl = Mesh.cylinder(radius: radius, height: len, slices: 16)
                .rotated(by: Euclid.Rotation.roll(.radians(.pi / 2 - theta)))
                .translated(by: Vector(cx, cy, midZ))
            parts.append(cyl)
        }

        // Square off the lower half so the bore is flat-bottom + arched-top
        // everywhere. Two pieces: a flat-bottomed vertical cylinder at each
        // waypoint (gives the junction a flat disc floor under the sphere's dome
        // instead of the sphere's rounded lower hemisphere), and a flat-floored
        // box along each straight run. The round cylinder's / sphere's lower half
        // is inscribed in these, so the union keeps the arched top and squares
        // only the bottom.
        if flatBottom {
            // Which half is the flat floor depends on the plate's print
            // orientation: the arch faces the outer face (the up side when printed
            // dimples-down), so the top plate's floor sits below the midline and
            // the flipped bottom plate's floor sits above it.
            let floorCenterZ = midZ + (flipFloor ? radius / 2 : -radius / 2)
            for p in waypoints {
                parts.append(junctionFloorCylinder(at: p, radius: radius, floorCenterZ: floorCenterZ))
            }
            for i in 0..<(waypoints.count - 1) {
                let a = waypoints[i]
                let b = waypoints[i + 1]
                let dx = b.x - a.x
                let dy = b.y - a.y
                let len = (dx * dx + dy * dy).squareRoot()
                guard len > 0 else { continue }
                let cx = (a.x + b.x) / 2
                let cy = (a.y + b.y) / 2
                let theta = atan2(dy, dx)
                parts.append(floorBox(cx: cx, cy: cy, len: len, theta: theta,
                                      radius: radius, floorCenterZ: floorCenterZ))
            }
        }

        return Mesh.union(parts)
    }

    /// A loose, render-only mesh of one physical volume's channel network plus
    /// a marker bead at each probe hole — for tinted highlighting in the 3D
    /// preview. Reuses the real channel primitive, slightly inflated so it sits
    /// proud of the carved channel (no z-fighting). Polygons are concatenated,
    /// not CSG-unioned: the overlap is invisible for an opaque highlight and far
    /// cheaper than a boolean union across the whole cavity.
    static func volumeMesh(for volume: Volume, _ m: ManufacturingConstants) -> Mesh {
        let r = m.channelDiameter / 2 + 0.15
        var polys: [Polygon] = []
        for seg in volume.segments where seg.positions.count >= 2 {
            polys += channelMesh(waypoints: seg.positions, radius: r,
                                 midZ: m.midZ(for: seg.layer),
                                 flatBottom: m.flatBottomChannels,
                                 flipFloor: seg.layer.plate == .bottom).polygons
        }
        // A bead at every hole so probe points stay visible even for a cavity
        // with little or no routed channel (e.g. a short abutment-only stub).
        for hole in volume.holes {
            polys += Mesh.sphere(radius: r + 0.1, slices: 16)
                .translated(by: Vector(hole.pos.x, hole.pos.y, m.midZ(for: hole.layer)))
                .polygons
        }
        return Mesh(polys)
    }

    /// Flat-floored box for one channel segment, occupying the lower half of the
    /// bore (from the bore floor up to the midline). Same Y-aligned-then-rolled
    /// convention as the segment cylinders so it lands exactly along the segment.
    ///
    /// `overlap` (a hair, well below print resolution) makes the box strictly
    /// engulf the cylinder in width, depth, and a touch above the midline rather
    /// than sit tangent to it — the same tangency-avoidance trick as the sphere
    /// radius bump, so the union has no coplanar/tangent degeneracies. The box
    /// stops at its waypoints (extended only by `overlap`, not a full `radius`):
    /// at a bend the two segments' boxes already overlap in an r×r block from
    /// their widths, so the flat floor stitches watertight there, and the
    /// `overlap` covers the collinear pass-through case. Extending by a full
    /// radius instead would poke square corners out past the rounded sphere
    /// junction (visible "ears" at every bend); stopping at the waypoint lets
    /// the sphere keep the junction rounded.
    private static func floorBox(
        cx: Double, cy: Double, len: Double, theta: Double,
        radius: Double, floorCenterZ: Double
    ) -> Mesh {
        let overlap = 0.01
        // X = width across channel, Y = length along segment, Z = height. Spans
        // half the bore, centred at `floorCenterZ`; which half is the flat floor
        // (toward the plate's outer face) is the caller's choice via `flipFloor`.
        let size = Vector(2 * radius + 2 * overlap, len + 2 * overlap, radius + 2 * overlap)
        return Mesh.cube(size: size)
            .rotated(by: Euclid.Rotation.roll(.radians(.pi / 2 - theta)))
            .translated(by: Vector(cx, cy, floorCenterZ))
    }

    /// Vertical cylinder filling the floor half of the bore at a waypoint: gives
    /// the junction a flat circular floor under the joint sphere's dome, instead
    /// of the sphere's rounded hemisphere on that side. The radius matches the
    /// sphere (`radius + 0.005`) so the dome flows straight into the cylinder wall
    /// and the sphere's near half is absorbed; centred at `floorCenterZ` (same
    /// z-band as `floorBox`) so the disc floor is coplanar with the straight-run
    /// floors. Same Y-axis→vertical rotation as the drop bores.
    private static func junctionFloorCylinder(
        at p: Point, radius: Double, floorCenterZ: Double
    ) -> Mesh {
        let overlap = 0.01
        return Mesh.cylinder(radius: radius + 0.005, height: radius + 2 * overlap, slices: 16)
            .rotated(by: Euclid.Rotation.pitch(.halfPi))
            .translated(by: Vector(p.x, p.y, floorCenterZ))
    }

    // MARK: - Drop bores

    /// Vertical cylinder connecting a pin location at channel-midline depth to the
    /// silicone-facing surface of `layer`. Overshoots both ends by a small epsilon
    /// so CSG cuts are clean rather than tangent.
    private static func dropBoreMesh(
        at p: Point, onPlate plate: Plate, radius: Double,
        topInnerZ: Double, bottomInnerZ: Double,
        topMidZ: Double, bottomMidZ: Double
    ) -> Mesh {
        let eps = 0.05
        let zLo: Double, zHi: Double
        switch plate {
        case .top:
            // Drop from midline DOWN to silicone face.
            zLo = topInnerZ - eps
            zHi = topMidZ + eps
        case .bottom:
            // Drop from midline UP to silicone face.
            zLo = bottomMidZ - eps
            zHi = bottomInnerZ + eps
        }
        let len = zHi - zLo
        let cz = (zLo + zHi) / 2
        return Mesh.cylinder(radius: radius, height: len, slices: 16)
            .rotated(by: Euclid.Rotation.pitch(.halfPi))
            .translated(by: Vector(p.x, p.y, cz))
    }

    // MARK: - Via

    /// Vertical cylinder spanning between the two twins of a via. With
    /// multi-layer plates the twins can be on the same plate at different
    /// depths (a tube *inside* one plate), or on opposite plates (the
    /// traditional silicone-crossing via). Either way the cutter is one
    /// cylinder; the caller decides which plate(s) it should subtract from.
    /// Silicone between top and bottom plates is the user's job to punch at
    /// the same XY at assembly.
    private static func viaCutterMesh(
        at p: Point, radius: Double, zLo: Double, zHi: Double
    ) -> Mesh {
        let eps = 0.05
        let lo = zLo - eps
        let hi = zHi + eps
        let len = hi - lo
        let cz = (hi + lo) / 2
        return Mesh.cylinder(radius: radius, height: len, slices: 24)
            .rotated(by: Euclid.Rotation.pitch(.halfPi))
            .translated(by: Vector(p.x, p.y, cz))
    }

    private static func approxEqualXY(_ a: Point, _ b: Point, eps: Double = 0.05) -> Bool {
        abs(a.x - b.x) < eps && abs(a.y - b.y) < eps
    }

    // MARK: - Dimples

    /// Dome-shaped dimple cavity: a sphere whose centre sits
    /// `dimpleSphereOffset` mm into the silicone gap from the plate's
    /// silicone-facing surface. The cap that intrudes into the plate is the
    /// cavity — widest at the surface, tapering inward. Intersected with a
    /// half-space cube so the cutter is bounded at the plate surface; otherwise
    /// the rest of the sphere would render through the silicone gap in the
    /// channels-only view.
    private static func dimpleMesh(
        at center: Point, layer: Plate, m: ManufacturingConstants,
        topInnerZ: Double, bottomInnerZ: Double
    ) -> Mesh {
        let radius = m.dimpleDiameter / 2
        let offset = m.dimpleSphereOffset
        let eps = 0.05
        let cz: Double
        let clipLo: Double
        let clipHi: Double
        switch layer {
        case .top:
            cz = topInnerZ - offset
            clipLo = topInnerZ - eps               // overshoot surface by eps for clean CSG
            clipHi = topInnerZ + radius + 1        // safely above the cap's deepest point
        case .bottom:
            cz = bottomInnerZ + offset
            clipLo = bottomInnerZ - radius - 1
            clipHi = bottomInnerZ + eps
        }
        let sphere = Mesh.sphere(radius: radius, slices: 32)
            .translated(by: Vector(center.x, center.y, cz))
        let clipper = Mesh.cube(
            center: Vector(center.x, center.y, (clipLo + clipHi) / 2),
            size: Vector(2 * radius + 1, 2 * radius + 1, clipHi - clipLo)
        )
        return sphere.intersection(clipper)
    }

    // MARK: - LED features

    /// LED dimple cavity. Identical construction to the transistor dimple
    /// (spherical cap intruding into the plate from the silicone-facing
    /// surface) but parameterised by `ledDimpleDiameter` and `ledDimpleDepth`
    /// — both raw values entered by the user, no derivation.
    private static func ledDimpleMesh(
        at center: Point, layer: Plate, m: ManufacturingConstants,
        topInnerZ: Double, bottomInnerZ: Double
    ) -> Mesh {
        let radius = m.ledDimpleDiameter / 2
        let offset = m.ledDimpleDepth
        let eps = 0.05
        let cz: Double
        let clipLo: Double
        let clipHi: Double
        switch layer {
        case .top:
            cz = topInnerZ - offset
            clipLo = topInnerZ - eps
            clipHi = topInnerZ + radius + 1
        case .bottom:
            cz = bottomInnerZ + offset
            clipLo = bottomInnerZ - radius - 1
            clipHi = bottomInnerZ + eps
        }
        let sphere = Mesh.sphere(radius: radius, slices: 32)
            .translated(by: Vector(center.x, center.y, cz))
        let clipper = Mesh.cube(
            center: Vector(center.x, center.y, (clipLo + clipHi) / 2),
            size: Vector(2 * radius + 1, 2 * radius + 1, clipHi - clipLo)
        )
        return sphere.intersection(clipper)
    }

    /// LED viewing hole — a cylinder punched all the way through `plate`
    /// (silicone face to outer face) at the dimple's XY, with the requested
    /// diameter. Overshoots both faces by a small epsilon so the CSG cut is
    /// clean rather than tangent.
    private static func ledViewHoleMesh(
        at center: Point, onPlate plate: Plate, diameter: Double,
        topInnerZ: Double, bottomInnerZ: Double,
        topThickness: Double, bottomThickness: Double,
        outerOvershoot: Double = 0
    ) -> Mesh {
        let radius = diameter / 2
        let eps = 0.1
        let zLo: Double, zHi: Double
        switch plate {
        case .top:
            zLo = topInnerZ - eps
            zHi = topInnerZ + topThickness + eps + outerOvershoot
        case .bottom:
            zLo = bottomInnerZ - bottomThickness - eps - outerOvershoot
            zHi = bottomInnerZ + eps
        }
        let len = zHi - zLo
        let cz = (zLo + zHi) / 2
        return Mesh.cylinder(radius: radius, height: len, slices: 32)
            .rotated(by: Euclid.Rotation.pitch(.halfPi))
            .translated(by: Vector(center.x, center.y, cz))
    }

    // MARK: - Source/drain pads

    /// Source/drain pad cavities for one transistor placement. The pads come
    /// from lathing a filleted 2D profile (a "D" shape with a rounded corner
    /// where the spherical surface meets the flat face) around the source-
    /// drain axis, then mirroring for the other pad and clipping to the
    /// plate body so the cavity stays inside one plate.
    ///
    /// With `padsFilletRadius = 0` (or out of valid range) the profile has
    /// a sharp corner and the geometry matches the previous sphere-minus-
    /// strip construction.
    private static func padsCavityMesh(
        placement: Placement, m: ManufacturingConstants,
        topInnerZ: Double, bottomInnerZ: Double
    ) -> Mesh {
        let radius = m.padsDiameter / 2
        let sep = m.padsSeparation
        let fillet = m.padsFilletRadius
        let oppositePlate = placement.layer.opposite
        let oppositeInnerZ = oppositePlate == .top ? topInnerZ : bottomInnerZ

        // The lathed pad solid is already closed — `filletedPadsSolid` makes
        // a spherical cap with a flat back disk, watertight by construction.
        // An earlier revision intersected it with a body-cube half-space to
        // keep the cavity's lower radial half from poking into the silicone
        // gap in the "Channels" preview. That intersection cut the pad
        // sphere right next to its equator (the densest band of Euclid's
        // sphere triangulation) and generated hairline slivers that showed
        // up as open edges in the exported STL. Skipping the clip lets the
        // pad extend ~1 mm past the plate's silicone face in the preview
        // — cosmetic, since the plate subtraction outside the plate is a
        // no-op and the printed cavity is unchanged.
        let cavityLocal = filletedPadsSolid(R: radius, sep: sep, fillet: fillet)

        let rotated = cavityLocal.rotated(
            by: Euclid.Rotation.roll(.radians(placement.rotation.radians))
        )
        return rotated.translated(by: Vector(
            placement.position.x, placement.position.y, oppositeInnerZ
        ))
    }

    /// Builds the two pad solids (filleted spherical caps) symmetric across
    /// the gate centre along the source-drain (local X) axis, joined into a
    /// single mesh. Built in lathe space (revolve around lathe Y axis) and
    /// then rotated so Y → local X.
    static func filletedPadsSolid(R: Double, sep: Double, fillet: Double) -> Mesh {
        let maxFillet = (R - sep / 2) / 2 - 0.001
        let f = max(0, min(fillet, maxFillet))
        let validFillet = f > 0

        // Fillet centre at (yc, sep/2 + f) in (radial, axial). With f = 0
        // this degenerates to the sharp corner at (yc, sep/2).
        let yc: Double
        let xt: Double
        let yt: Double
        if validFillet {
            yc = ((R - f) * (R - f) - (sep / 2 + f) * (sep / 2 + f)).squareRoot()
            xt = R * (sep / 2 + f) / (R - f)
            yt = R * yc / (R - f)
        } else {
            yc = (R * R - (sep / 2) * (sep / 2)).squareRoot()
            xt = sep / 2
            yt = yc
        }

        // Profile in lathe frame: X = radial distance from axis, Y = axial
        // (becomes local X after the final rotation). Path is open and starts
        // and ends on the axis (X = 0) so the lathe closes it into a solid.
        var pts: [Vector] = []
        pts.append(Vector(0, sep / 2, 0))         // axis at base
        pts.append(Vector(yc, sep / 2, 0))        // outer edge of flat face

        if validFillet {
            // Fillet arc samples, from (yc, sep/2) at angle −π/2 around
            // fillet centre, sweeping to (yt, xt) where the arc meets the
            // sphere tangentially.
            let nFillet = 12
            let a0 = -Double.pi / 2                   // base of fillet on flat face
            let aEnd = atan2(sep / 2 + f, yc)         // tangent to sphere
            for i in 1...nFillet {
                let t = Double(i) / Double(nFillet)
                let angle = a0 + t * (aEnd - a0)
                let rx = yc + f * cos(angle)
                let ry = (sep / 2 + f) + f * sin(angle)
                pts.append(Vector(rx, ry, 0))
            }
        }

        // Sphere arc samples from (yt, xt) up to the pole (0, R). Lathe-frame
        // angle: atan2(axial, radial) so angle 0 = equator (R, 0), π/2 = pole.
        let nSphere = 20
        let sA0 = atan2(xt, yt)
        let sA1 = Double.pi / 2
        for i in 1...nSphere {
            let t = Double(i) / Double(nSphere)
            let angle = sA0 + t * (sA1 - sA0)
            pts.append(Vector(R * cos(angle), R * sin(angle), 0))
        }

        let path = Path(pts.map { PathPoint.point($0) })
        let rightPadLathe = Mesh.lathe(path, slices: 32)

        // Left pad = right pad reflected through the lathe origin along the
        // axial direction. roll(.pi) around Z flips (x, y) → (−x, −y); the
        // pad is symmetric in the radial direction so this just mirrors the
        // axial side.
        let leftPadLathe = rightPadLathe.rotated(by: Euclid.Rotation.roll(.pi))
        let bothLathe = rightPadLathe.union(leftPadLathe)

        // Lathe Y axis → local X axis. roll(−π/2) maps (x, y, z) → (y, −x, z),
        // so the axial direction now points along local +X / −X.
        return bothLathe.rotated(by: Euclid.Rotation.roll(-.halfPi))
    }

    // MARK: - Resistor serpentine

    private static func resistorSerpentineMesh(
        placement: Placement, component: Component, m: ManufacturingConstants,
        topMidZ: Double, bottomMidZ: Double
    ) -> Mesh {
        _ = topMidZ; _ = bottomMidZ
        // Footprint is the same physical size for S/M/L; the resistor size
        // picks how many times the channel zigzags inside it. Path generator
        // is shared with the physical-canvas glyph so the preview and the
        // printed channel match. Resistors are pure tubes — they can live on
        // any channel-layer depth, so the serpentine's midZ comes from the
        // placement's depth (defaults to 0 for legacy files).
        let halfLen = ManufacturingConstants.resistorFootprintLength / 2
        let halfWid = ManufacturingConstants.resistorFootprintWidth / 2
        let transitions = ResistorGeometry.transitions(for: component.resistorSize ?? .medium)
        let local = ResistorGeometry.path(transitions: transitions, halfLen: halfLen, halfWid: halfWid)
        let world = local.map { transformLocalToWorld($0, placement: placement) }
        let midZ = m.midZ(for: Layer(plate: placement.layer, depth: placement.depth))
        return channelMesh(waypoints: world, radius: m.resistorChannelDiameter / 2, midZ: midZ)
    }

    // MARK: - Edge ports

    /// Edge port bore. Diameter at the route end is `portBoreDiameter`;
    /// the bore widens outward at `portBoreTaperDegrees` along the path
    /// to the board edge — the route end is the narrow opening, the edge
    /// face is the wide opening. Built by lathing a trapezoidal profile
    /// around the bore axis.
    static func portBoreMesh(
        placement: Placement, outline: Rect, m: ManufacturingConstants,
        topMidZ: Double, bottomMidZ: Double
    ) -> Mesh {
        let routeR = m.portBoreDiameter / 2
        let taperRad = m.portBoreTaperDegrees * .pi / 180
        // Port bores follow `placement.depth` like resistors do, since they're
        // just holes drilled into the plate. Falls back to the depth-0 mid-Z
        // the rest of the pipeline already passed in when the placement is on
        // depth 0 (the common case), but reads from `midZ` for deeper layers.
        let bz: Double
        if placement.depth == 0 {
            bz = placement.layer == .top ? topMidZ : bottomMidZ
        } else {
            bz = m.midZ(for: Layer(plate: placement.layer, depth: placement.depth))
        }
        let p = placement.position
        let eps = 0.5

        // Length from the route end (placement) to the overshot edge, plus
        // the rotation applied to a lathe mesh oriented along +Y. Euclid's
        // `Rotation.roll(θ)` is internally a rotation by `-θ` (see
        // Rotation.swift's quaternion init), so the +X mapping uses
        // `roll(+π/2)` and the -X mapping uses `roll(-π/2)`.
        let length: Double
        let yawAroundZ: Double
        switch placement.rotation {
        case .r0:                                            // exits +X edge
            length = outline.maxX + eps - p.x
            yawAroundZ =  .pi / 2                            // Y → +X
        case .r180:                                          // exits -X edge
            length = p.x - (outline.minX - eps)
            yawAroundZ = -.pi / 2                            // Y → -X
        case .r90:                                           // exits +Y edge
            length = outline.maxY + eps - p.y
            yawAroundZ = 0                                   // already along +Y
        case .r270:                                          // exits -Y edge
            length = p.y - (outline.minY - eps)
            yawAroundZ = .pi                                 // Y → -Y
        }

        // Edge radius widens as we move outward.
        let edgeR = routeR + length * tan(taperRad)
        let bore = taperedBoreSolid(routeEndR: routeR, edgeR: edgeR, length: length)
            .rotated(by: Euclid.Rotation.roll(.radians(yawAroundZ)))
            .translated(by: Vector(p.x, p.y, bz))
        return bore
    }

    /// Trapezoidal lathe profile revolved into a frustum aligned along the
    /// lathe Y axis. The route-end disk (radius `routeEndR`) sits at Y=0;
    /// the edge-end disk (radius `edgeR`) sits at Y=`length`. Callers wrap
    /// with the placement's yaw so Y maps to the bore's world-axis direction.
    static func taperedBoreSolid(routeEndR: Double, edgeR: Double, length: Double) -> Mesh {
        let pts: [Vector] = [
            Vector(0, 0, 0),                  // pole at route end (Y=0)
            Vector(routeEndR, 0, 0),          // route-end radius
            Vector(edgeR, length, 0),         // edge radius
            Vector(0, length, 0),             // pole at edge (Y=length)
        ]
        let path = Path(pts.map { PathPoint.point($0) })
        return Mesh.lathe(path, slices: 24)
    }

    // MARK: - Transform helpers

    private static func transformLocalToWorld(_ p: Point, placement: Placement) -> Point {
        let r = placement.rotation.radians
        let c = cos(r)
        let s = sin(r)
        return Point(
            x: placement.position.x + p.x * c - p.y * s,
            y: placement.position.y + p.x * s + p.y * c
        )
    }

    private static func appendCutter(
        _ mesh: Mesh, plate: Plate,
        top: inout [Mesh], bottom: inout [Mesh]
    ) {
        switch plate {
        case .top:    top.append(mesh)
        case .bottom: bottom.append(mesh)
        }
    }
}
