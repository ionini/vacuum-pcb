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
    /// Document-level flag (lives on `CircuitDocument`, not `manufacturing`),
    /// drafted here so it commits through the same Apply/Revert flow.
    @State private var draftSkipEdgeWall: Bool = false
    @State private var initialized = false
    /// Cross-document parameter clipboard, mirrored here so iPad (no menu
    /// bar) can reach the same Copy / Paste the Edit menu offers on macOS.
    @ObservedObject private var clipboard = ManufacturingClipboard.shared
    @State private var pasteRequest: ManufacturingPasteRequest?

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
                row("Min channel spacing (routing)", $draftMfg.minChannelSpacing)
                row("Min wall thickness (DRC)", $draftMfg.minWallThickness)
                Text("Port bore diameter is the narrow (route-side) end. The bore tapers outward at the given draft angle so it widens toward the board edge — 0° gives a straight cylinder.")
                    .font(.caption2).foregroundStyle(.secondary)
                // Purely a 3D/print property (no effect on the 2D layout/DRC), so
                // it lives in the full (3D Preview) inspector only, like the
                // stencil thickness and plate/screw geometry.
                if scope == .full {
                    Toggle("Flat-bottom channels", isOn: $draftMfg.flatBottomChannels)
                        .font(.caption)
                    Text("Squares off the lower half of each routing channel (flat floor, arched top) for more void volume; the arch faces each plate's outer face so both plates stay printable. Off = round bores. Resistor bores are always round.")
                        .font(.caption2).foregroundStyle(.secondary)
                    row("Test point label size", $draftMfg.testPointLabelSize)
                    Text("Font size (mm) of the raised name embossed around each testing point's hole on the plate's outer face. Set 0 to hide the labels.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            if scope == .full {
                group("Print envelope") {
                    row("Envelope padding XY (walls)", $draftMfg.modifierMarginXY)
                    row("Envelope padding Z (roof/floor)", $draftMfg.modifierMarginZ)
                    Text("How far the print envelope (the Bambu modifier volume) grows past every channel, valve, via and port — the wall of material it claims around the pneumatics, e.g. to print solid where it matters and hollow elsewhere. Visible as the purple overlay in the 3D preview (Layers → Print envelope), where a slider drives both values together. Independent of the DRC wall warnings.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            // DRC scope toggle. A document-level flag (not a manufacturing
            // constant), shown in both inspector scopes since it governs the
            // same DRC the min-wall row feeds.
            group("Design rules") {
                Toggle("Reusable component", isOn: $draftSkipEdgeWall)
                    .font(.caption)
                Text("Skips the board-edge thin-wall warnings for this design — its outline isn't a real outer face when it's embedded as a sub-part inside a larger board. Internal channel and bore wall checks still run, and any design that embeds this part re-checks its own edges normally.")
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
                row("Screw hole padding", $draftMfg.stencilScrewPadding)
                Text(scope == .full
                     ? "Flat cutting template exported next to the plates. Holes at every cross-silicone via and screw shaft; sized to the silicone sheet so it doubles as a 1:1 cutting guide. Via hole padding adds to each via hole's diameter (0–2 mm) to compensate for the silicone plug contracting when squished between the plates. Screw hole padding does the same for every screw bore (0–6 mm on top of the 2.2 mm shaft clearance, standalone and connector end-cap alike) — no fluid crosses those, so they can be opened up well past the via holes to keep the silicone from being pinched against the shaft."
                     : "Via hole padding adds to each cross-silicone via hole's diameter in the stencil (0–2 mm) to compensate for the silicone plug contracting when squished between the plates. Screw hole padding does the same for every screw bore (0–6 mm on top of the 2.2 mm shaft clearance) — no fluid crosses those, so they can be opened up well past the via holes.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if scope == .full {
                group("Mold") {
                    row("Casting margin", $draftMfg.castingMargin)
                    row("Wall thickness", $draftMfg.moldWallThickness)
                    Text("Open frame (\"cookie cutter\") for casting the silicone sheet, printed alongside the plates at exactly the silicone thickness. Casting margin is the gap between the board outline and the frame's inner wall — keep it ≥ ~1.5 mm so the cut part stays inboard of the meniscus the silicone climbs against the wall. The pour volume in the sidebar is computed against this cavity. Wall thickness is the printed rim; set 0 to disable the frame.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
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

            Divider()

            group("Reuse in another design") {
                HStack(spacing: 8) {
                    Button {
                        ManufacturingClipboard.shared.store(
                            document.circuit.manufacturing,
                            from: ManufacturingClipboard.frontmostDocumentName())
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    if clipboard.hasContent {
                        Button {
                            pasteRequest = .fromClipboard()
                        } label: {
                            Label("Paste…", systemImage: "doc.on.clipboard")
                        }
                    }
                }
                .buttonStyle(.bordered)
                .font(.caption)
                Text("Copies this design's *applied* parameters (hit Apply first if you just edited a field). Paste into another open design and confirm which values to take — same as Edit ▸ Copy/Paste Manufacturing Parameters (⌥⌘C / ⌥⌘V). Board size isn't included.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .manufacturingPasteConfirmation(request: $pasteRequest, document: $document)
        .onAppear { syncFromDocument(force: true) }
        // External changes (file open, Undo if it ever lands) reset the draft.
        // Skip during initial onAppear-vs-first-render to avoid stomping the
        // initial sync.
        .onChange(of: document.circuit.manufacturing) { _, _ in syncFromDocument() }
        .onChange(of: document.circuit.physical.boardOutline) { _, _ in syncFromDocument() }
        .onChange(of: document.circuit.skipEdgeWallDRC) { _, _ in syncFromDocument() }
    }

    private var hasChanges: Bool {
        draftMfg != document.circuit.manufacturing
            || draftBoard != document.circuit.physical.boardOutline.size
            || draftSkipEdgeWall != (document.circuit.skipEdgeWallDRC ?? false)
    }

    private func apply() {
        // Clamps on commit (so a stray 0 in the field can't slip into the
        // CSG) and migrates route endpoints off any footprint pin the new
        // values moved. Shared with the Edit-menu paste.
        ManufacturingActions.commit(draftMfg, to: &document)
        document.circuit.physical.boardOutline.size =
            ManufacturingActions.sanitizedSize(draftBoard)
        // Store nil for "off" so a design that never flags itself stays
        // byte-identical to a v7 doc (and its content hash is unchanged).
        document.circuit.skipEdgeWallDRC = draftSkipEdgeWall ? true : nil
        // Sync the draft back from the clamped values so the UI mirrors what
        // actually landed.
        syncFromDocument(force: true)
    }

    private func revert() {
        syncFromDocument(force: true)
    }

    private func syncFromDocument(force: Bool = false) {
        let mfg = document.circuit.manufacturing
        let size = document.circuit.physical.boardOutline.size
        let skipEdgeWall = document.circuit.skipEdgeWallDRC ?? false
        // Don't clobber an in-progress edit unless explicitly forced.
        if force || !initialized {
            draftMfg = mfg
            draftBoard = size
            draftSkipEdgeWall = skipEdgeWall
            initialized = true
        } else if !hasChanges {
            draftMfg = mfg
            draftBoard = size
            draftSkipEdgeWall = skipEdgeWall
        }
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
