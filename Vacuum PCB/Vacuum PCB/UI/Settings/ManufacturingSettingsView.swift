import SwiftUI

/// Editable list of every manufacturing constant plus the board outline.
///
/// Edits land in a *draft* copy held in @State; nothing is written back to
/// the document until the user hits Apply. That avoids two annoyances of the
/// live-binding version:
///  * Typing "0.5" causes intermediate values like "0" or "0." to trigger
///    rebuilds (or clamp away the cursor's intended value).
///  * Switching tabs while a TextField holds an uncommitted value used to
///    silently drop the edit.
///
/// Apply writes the draft back into the document, which trips the
/// `previewDirty` flag in DocumentView — the next visit to the 3D preview
/// tab (or hitting Export) rebuilds the CSG against the new values. Revert
/// throws the draft away and re-syncs from the document.
struct ManufacturingSettingsView: View {
    /// `.full` (3D Preview inspector) shows every constant. `.physical`
    /// (Physical inspector) mirrors only the constants that shape the 2D
    /// layout — footprints, routing/DRC, the snap grid, LED size, via-hole
    /// padding — and drops the purely-3D ones (plate/dome/screw geometry) and
    /// the board size (the Physical inspector already edits that live).
    enum Scope { case full, physical }

    @Binding var document: VPCBDocument
    var scope: Scope = .full

    @State private var draftMfg: ManufacturingConstants = .defaults
    @State private var draftBoard: Size = Size(width: 50, height: 30)
    @State private var initialized = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manufacturing").font(.title3).bold()

            if scope == .full {
                group("Board") {
                    row("Width", $draftBoard.width)
                    row("Height", $draftBoard.height)
                }

                group("Plates") {
                    row("Plate thickness (single-layer)", $draftMfg.plateThickness)
                    row("Silicone thickness", $draftMfg.siliconeThickness)
                    row("Inter-layer wall", $draftMfg.interLayerWall)
                    row("Corner fillet radius", $draftMfg.plateCornerFillet)
                    Text("Multi-layer plates: plate thickness above is the depth-0 plate height. Each extra channel layer adds channelDiameter + inter-layer wall to that plate's height. Corner fillet rounds the four vertical edges of each plate (viewed from above) — softens the print so the printer doesn't have to resolve a perfect 90° corner. Runs full plate height; silicone-facing faces stay rectangular. Set 0 for square corners.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            group("Channels") {
                row("Channel diameter", $draftMfg.channelDiameter)
                row("Resistor bore diameter", $draftMfg.resistorChannelDiameter)
                row("Port bore diameter", $draftMfg.portBoreDiameter)
                row("Port bore taper (°)", $draftMfg.portBoreTaperDegrees)
                row("Min channel spacing (DRC)", $draftMfg.minChannelSpacing)
                row("Min wall thickness (DRC)", $draftMfg.minWallThickness)
                Text("Port bore diameter is the narrow (route-side) end. The bore tapers outward at the given draft angle so it widens toward the board edge — 0° gives a straight cylinder.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            // Gate dome diameter sizes the transistor body drawn on the 2D
            // canvas and the pin-snap tolerance (like the LED diameter), so it
            // belongs in the physical mirror; sphere offset rides along.
            group("Transistor gate") {
                row("Dome diameter", $draftMfg.dimpleDiameter)
                row("Dome sphere offset", $draftMfg.dimpleSphereOffset)
                Text("Dome is a sphere of the diameter above, centred this far into the silicone gap from the plate face.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            group("LED indicator") {
                row("Dimple diameter", $draftMfg.ledDimpleDiameter)
                row("Dimple depth", $draftMfg.ledDimpleDepth)
                Text("LED dome is a sphere of the diameter above, centred this far into the silicone gap from the plate face (raw value, not derived). The opposite plate gets a cylindrical viewing hole 1 mm wider than the dimple, all the way through, so the silicone deflection is visible.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            group("Transistor source/drain pads") {
                row("Pads diameter", $draftMfg.padsDiameter)
                row("Pads separation", $draftMfg.padsSeparation)
                row("Tube offset (centre)", $draftMfg.padsOffset)
                row("Edge fillet radius", $draftMfg.padsFilletRadius)
                Text("Two cap-shaped cavities on the opposite plate, split by a strip of this width along the source-drain axis. Tube offset is the distance from the gate centre to each drop-bore tube. Fillet radius rounds the sharp edge between the spherical surface and the flat face (set 0 for a sharp corner).")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if scope == .full {
                group("Screws") {
                    row("Head depth", $draftMfg.screwHeadDepth)
                    row("Nut depth", $draftMfg.screwNutDepth)
                    row("Head/nut protrusion", $draftMfg.screwProtrusion)
                    row("Volcano base diameter", $draftMfg.screwDomeBaseDiameter)
                    Text("Head and nut depths size the countersink and hex pocket to whatever fastener you're using (defaults match an M2-class screw). Protrusion is how far the head and nut stick past their plate's outer face — 0 keeps both flush. Positive values reduce the inlay and rise a Mt-Fuji-shaped volcano around the protruding portion so the head/nut is still held by printed material on the sides; the cavity stays open at the top so a driver can still reach the fastener. Volcano base diameter sets how wide the dome is at its base; the flat plateau on top always sits 0.75 mm outside the cavity, so widening the base only widens the slope. Volcano fields are ignored when protrusion is 0.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            group("Stencil") {
                if scope == .full { row("Thickness", $draftMfg.stencilThickness) }
                row("Via hole padding", $draftMfg.stencilViaPadding)
                Text(scope == .full
                     ? "Flat cutting template exported next to the plates. Holes at every cross-silicone via and screw shaft; sized to the silicone sheet so it doubles as a 1:1 cutting guide. Via hole padding adds to each via hole's diameter (0–2 mm) to compensate for the silicone plug contracting when squished between the plates."
                     : "Via hole padding adds to each cross-silicone via hole's diameter in the stencil (0–2 mm) to compensate for the silicone plug contracting when squished between the plates.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            group("Editor") {
                row("Grid pitch", $draftMfg.gridPitch)
                Text("Grid only affects physical-canvas snapping, not the 3D mesh.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            HStack {
                Button("Revert", action: revert).disabled(!hasChanges)
                Spacer()
                Button("Apply", action: apply)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(!hasChanges)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 6)
        }
        .onAppear { syncFromDocument(force: true) }
        // External changes (file open, Undo if it ever lands) reset the draft.
        // Skip during initial onAppear-vs-first-render to avoid stomping the
        // initial sync.
        .onChange(of: document.circuit.manufacturing) { _, _ in syncFromDocument() }
        .onChange(of: document.circuit.physical.boardOutline) { _, _ in syncFromDocument() }
    }

    private var hasChanges: Bool {
        draftMfg != document.circuit.manufacturing
            || draftBoard != document.circuit.physical.boardOutline.size
    }

    private func apply() {
        // Clamp on commit so a stray 0 in the field can't slip into the CSG.
        let newMfg = sanitized(draftMfg)
        let oldMfg = document.circuit.manufacturing
        // Migrate any route endpoint sitting at an old pin position over to
        // the new one, so changing padsOffset (or anything else that shifts
        // a footprint pin) doesn't strand routes on stale coordinates.
        if newMfg != oldMfg {
            migrateRouteEndpoints(oldMfg: oldMfg, newMfg: newMfg)
        }
        document.circuit.manufacturing = newMfg
        document.circuit.physical.boardOutline.size = sanitizedSize(draftBoard)
        // Sync the draft back from the clamped values so the UI mirrors what
        // actually landed.
        syncFromDocument(force: true)
    }

    /// Walks every transistor placement, compares old vs. new pin world
    /// positions, and rewrites any route segment's first/last `.point`
    /// waypoint that's sitting on an old pin position to the new one. Via
    /// waypoints are left alone — they have twins on the other side of the
    /// silicone and don't terminate at component pins.
    private func migrateRouteEndpoints(
        oldMfg: ManufacturingConstants, newMfg: ManufacturingConstants
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

    private func revert() {
        syncFromDocument(force: true)
    }

    private func syncFromDocument(force: Bool = false) {
        let mfg = document.circuit.manufacturing
        let size = document.circuit.physical.boardOutline.size
        // Don't clobber an in-progress edit unless explicitly forced.
        if force || !initialized {
            draftMfg = mfg
            draftBoard = size
            initialized = true
        } else if !hasChanges {
            draftMfg = mfg
            draftBoard = size
        }
    }

    // MARK: - Sanitisation

    private func sanitized(_ m: ManufacturingConstants) -> ManufacturingConstants {
        ManufacturingConstants(
            plateThickness: max(0.1, m.plateThickness),
            channelDiameter: max(0.05, m.channelDiameter),
            portBoreDiameter: max(0.05, m.portBoreDiameter),
            portBoreTaperDegrees: max(0.0, min(45.0, m.portBoreTaperDegrees)),
            siliconeThickness: max(0.05, m.siliconeThickness),
            dimpleDiameter: max(0.1, m.dimpleDiameter),
            dimpleDepth: max(0.05, m.dimpleDepth),
            dimpleSphereOffset: max(0.0, m.dimpleSphereOffset),
            padsDiameter: max(0.1, m.padsDiameter),
            padsSeparation: max(0.0, m.padsSeparation),
            padsOffset: max(0.0, m.padsOffset),
            padsFilletRadius: max(0.0, m.padsFilletRadius),
            gridPitch: max(0.05, m.gridPitch),
            minChannelSpacing: max(0.05, m.minChannelSpacing),
            resistorChannelDiameter: max(0.05, m.resistorChannelDiameter),
            interLayerWall: max(0.1, m.interLayerWall),
            plateCornerFillet: max(0.0, m.plateCornerFillet),
            ledDimpleDiameter: max(0.1, m.ledDimpleDiameter),
            ledDimpleDepth: max(0.0, m.ledDimpleDepth),
            screwProtrusion: max(0.0, m.screwProtrusion),
            screwDomeBaseDiameter: max(ScrewGeometry.headDiameter + 0.2,
                                       m.screwDomeBaseDiameter),
            screwHeadDepth: max(0.1, m.screwHeadDepth),
            screwNutDepth: max(0.1, m.screwNutDepth),
            stencilThickness: max(0.05, m.stencilThickness),
            stencilViaPadding: max(0.0, min(2.0, m.stencilViaPadding)),
            minWallThickness: max(0.05, m.minWallThickness)
        )
    }

    private func sanitizedSize(_ s: Size) -> Size {
        Size(width: max(1, s.width), height: max(1, s.height))
    }

    // MARK: - Row + group helpers

    @ViewBuilder private func group<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ label: String, _ value: Binding<Double>) -> some View {
        // The 64 pt field is comfortable next to a mouse-driven inspector
        // on macOS; on iPad the soft keyboard pushes the row up and the
        // narrow column becomes hard to verify, so widen it there.
        let fieldWidth: CGFloat = InputPlatform.isTouch ? 96 : 64
        return HStack(spacing: 8) {
            Text(label).font(.caption)
            Spacer(minLength: 4)
            // NumberFormatter (vs. the newer .number FormatStyle) parses
            // partial decimal input more reliably — e.g. SwiftUI's FormatStyle
            // path was rejecting "0.5" entered into a field whose current
            // value formatted as "1" with fractionLength(0...3).
            TextField("", value: value, formatter: Self.mmFormatter)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: fieldWidth)
            Text("mm").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private static let mmFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.allowsFloats = true
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 3
        f.usesGroupingSeparator = false
        return f
    }()
}
