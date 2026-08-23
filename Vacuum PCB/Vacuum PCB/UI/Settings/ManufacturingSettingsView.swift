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
///
/// Two timing rules keep the draft honest:
///  * Enter applies via `.onSubmit` (never a Return key-equivalent on the
///    button): the field editor commits the value into the draft *first*,
///    then apply runs, then focus is released — so ⌘Z afterwards reaches the
///    document's undo manager instead of the field editor's text undo.
///  * When the document changes underneath a live draft (parameter paste,
///    the envelope-padding slider, Undo), the draft is *rebased*: fields the
///    user actually edited keep their draft value, everything else follows
///    the document immediately. See `syncFromDocument`.
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
    /// The document state the draft was last synced from. Comparing the
    /// draft against this — not against the *current* document — is what
    /// tells a user edit apart from an external change when the document
    /// moves underneath us (paste, envelope slider, Undo).
    @State private var baselineMfg: ManufacturingConstants = .defaults
    @State private var baselineBoard: Size = Size(width: 50, height: 30)
    @State private var baselineSkipEdgeWall: Bool = false
    @State private var initialized = false
    /// True while any of the panel's number fields is being edited. Shared
    /// Bool binding across all rows: reading is "some field has focus",
    /// writing false resigns whichever field holds it.
    @FocusState private var fieldFocused: Bool
    /// Apply/Revert requested while a field was still focused. Dropping
    /// focus makes the field commit its pending text into the draft; the
    /// action itself runs from `.onChange(of: fieldFocused)`, which fires
    /// after that commit has landed — clicking a button doesn't move macOS
    /// focus, so running the action directly would read (Apply) or
    /// resurrect (Revert) a stale draft.
    @State private var pendingAction: DraftAction?
    private enum DraftAction { case apply, revert }
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
                row("Preferred wall (warn below)", $draftMfg.preferredWallThickness)
                Text("Min wall is the hard DRC limit — a thinner printed wall is expected to break through (error). Preferred wall is a softer bar: walls between the two report as yellow warnings. Set 0 to turn the warning tier off. Both are edge-to-edge and are also enforced inside placed sub-parts, using this board's constants.")
                    .font(.caption2).foregroundStyle(.secondary)
                spacingGuards
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
                    row("Through-hole diameter", $draftMfg.screwThroughDiameter)
                    row("Head depth", $draftMfg.screwHeadDepth)
                    row("Nut depth", $draftMfg.screwNutDepth)
                    row("Head/nut protrusion", $draftMfg.screwProtrusion)
                    row("Volcano base diameter", $draftMfg.screwDomeBaseDiameter)
                    Text("Through-hole diameter is the shaft's clearance bore through both plates — the screw must slip through freely, not thread into the plastic, or the plastic instead of the nut sets the plate separation (printed holes come out slightly undersized; when in doubt go wider). Head and nut depths size the countersink and hex pocket to whatever fastener you're using (defaults match an M2-class screw). Protrusion is how far the head and nut stick past their plate's outer face — 0 keeps both flush. Positive values reduce the inlay and rise a Mt-Fuji-shaped volcano around the protruding portion so the head/nut is still held by printed material on the sides; the cavity stays open at the top so a driver can still reach the fastener. Volcano base diameter sets how wide the dome is at its base; the flat plateau on top always sits 0.75 mm outside the cavity, so widening the base only widens the slope. Volcano fields are ignored when protrusion is 0.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            group("Stencil") {
                if scope == .full { row("Thickness", $draftMfg.stencilThickness) }
                row("Via hole padding", $draftMfg.stencilViaPadding)
                stencilHoleReadout(draftMfg.channelDiameter + draftMfg.stencilViaPadding)
                row("Screw hole padding", $draftMfg.stencilScrewPadding)
                stencilHoleReadout(draftMfg.screwThroughDiameter + draftMfg.stencilScrewPadding)
                Text(scope == .full
                     ? "Flat cutting template exported next to the plates. Holes at every cross-silicone via and screw shaft; sized to the silicone sheet so it doubles as a 1:1 cutting guide. Via hole padding adds to each via hole's diameter (0–2 mm) to compensate for the silicone plug contracting when squished between the plates. Screw hole padding does the same for every screw bore (0–6 mm on top of the screw through-hole diameter, standalone and connector end-cap alike) — no fluid crosses those, so they can be opened up well past the via holes to keep the silicone from being pinched against the shaft."
                     : "Via hole padding adds to each cross-silicone via hole's diameter in the stencil (0–2 mm) to compensate for the silicone plug contracting when squished between the plates. Screw hole padding does the same for every screw bore (0–6 mm on top of the screw through-hole diameter) — no fluid crosses those, so they can be opened up well past the via holes.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            group("Connector gasket") {
                row("Gasket width", $draftMfg.connectorGasketWidth)
                row("Via hole padding", $draftMfg.connectorGasketViaPadding)
                stencilHoleReadout(draftMfg.channelDiameter + draftMfg.connectorGasketViaPadding)
                row("Screw hole padding", $draftMfg.connectorGasketScrewPadding)
                stencilHoleReadout(draftMfg.screwThroughDiameter + draftMfg.connectorGasketScrewPadding)
                Text("Each bottom-extend connector's silicone is cut as its own crushed-gasket piece by a per-connector stencil: a stadium-shaped band concentric to the pin/screw row (cast in the same pour, separated when cut). Gasket width is the band's radial silicone past each pin hole's edge — it must stay inside the protrusion footprint to seal against plate on both sides. The paddings mirror the stencil's via/screw paddings but run wider by default: the crushed band stretches, closing pin holes inward (via padding compensates), and any silicone left near a screw shaft gets squeezed onto the threads and steals clamp force from the nut (screw padding keeps it clear).")
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
                Button("Revert") { run(.revert) }
                    .disabled(!hasChanges && !fieldFocused)
                Spacer()
                // No `.keyboardShortcut(.return)` here on purpose: a Return
                // key-equivalent races the focused field for the same
                // keypress, and if the button wins the field never commits —
                // Apply then writes the pre-keystroke draft. Enter instead
                // applies through `.onSubmit` below, which is guaranteed to
                // run *after* the field editor pushed the value into the
                // draft. While a field is focused the buttons stay enabled
                // even if the committed draft is clean — the field may hold
                // pending text that only becomes a change on commit.
                Button("Apply") { run(.apply) }
                    .disabled(!hasChanges && !fieldFocused)
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
        // Enter in any field: the field editor has already committed the
        // typed value into the draft by the time onSubmit fires, so apply
        // sees it. Releasing focus first means the canvas gets keyboard
        // events back and ⌘Z afterwards hits the document undo manager,
        // not the field editor's text undo.
        .onSubmit {
            fieldFocused = false
            apply()
        }
        .onChange(of: fieldFocused) { _, focused in
            guard !focused, let action = pendingAction else { return }
            pendingAction = nil
            switch action {
            case .apply: apply()
            case .revert: revert()
            }
        }
        .onAppear { syncFromDocument(force: true) }
        // External changes (paste, envelope slider, Undo, file reload)
        // rebase the draft onto the new document state — see
        // syncFromDocument for the merge rules.
        .onChange(of: document.circuit.manufacturing) { _, _ in syncFromDocument() }
        .onChange(of: document.circuit.physical.boardOutline) { _, _ in syncFromDocument() }
        .onChange(of: document.circuit.skipEdgeWallDRC) { _, _ in syncFromDocument() }
    }

    /// Runs Apply/Revert with the commit-before-action ordering described on
    /// `pendingAction`; immediate when no field is mid-edit.
    private func run(_ action: DraftAction) {
        if fieldFocused {
            pendingAction = action
            fieldFocused = false
        } else {
            switch action {
            case .apply: apply()
            case .revert: revert()
            }
        }
    }

    /// The board size participates only in the `.full` (3D Preview) scope —
    /// the Physical inspector edits it live outside this panel, so tracking
    /// it here would light up Apply for a change this panel doesn't show
    /// (and clicking Apply would then write the stale size back).
    private var hasChanges: Bool {
        draftMfg != document.circuit.manufacturing
            || (scope == .full
                && draftBoard != document.circuit.physical.boardOutline.size)
            || draftSkipEdgeWall != (document.circuit.skipEdgeWallDRC ?? false)
    }

    // MARK: - Consistency guards

    /// Live warnings on the draft values that keep the two spacing knobs
    /// coherent. `minChannelSpacing` is centre-to-centre (the auto-router's
    /// keep-out); the DRC walls are edge-to-edge — so the router only
    /// produces DRC-clean layouts when
    /// `spacing ≥ channelDiameter + minWallThickness`. Soft warnings with a
    /// one-tap fix, never a silent rewrite of the stored values.
    @ViewBuilder private var spacingGuards: some View {
        let errorFloor = draftMfg.channelDiameter + draftMfg.minWallThickness
        let warnFloor = draftMfg.channelDiameter + draftMfg.preferredWallThickness
        if draftMfg.minChannelSpacing < errorFloor {
            guardRow(
                String(format: "Routing spacing %.2f mm is centre-to-centre — below channel diameter + min wall (%.2f mm) the auto-router will produce layouts that fail DRC.",
                       draftMfg.minChannelSpacing, errorFloor),
                fixTitle: String(format: "Set spacing to %.2f mm", errorFloor)
            ) { draftMfg.minChannelSpacing = errorFloor }
        } else if draftMfg.preferredWallThickness > 0,
                  draftMfg.minChannelSpacing < warnFloor {
            guardRow(
                String(format: "Routing spacing %.2f mm satisfies the min wall but not the preferred wall — auto-routes will draw wall warnings. %.2f mm clears both.",
                       draftMfg.minChannelSpacing, warnFloor),
                fixTitle: String(format: "Set spacing to %.2f mm", warnFloor)
            ) { draftMfg.minChannelSpacing = warnFloor }
        }
        if draftMfg.interLayerWall < draftMfg.minWallThickness {
            guardRow(
                String(format: "Inter-layer wall %.2f mm is below the min wall %.2f mm — every stacked-layer channel pair fails DRC by construction.",
                       draftMfg.interLayerWall, draftMfg.minWallThickness),
                fixTitle: String(format: "Set inter-layer wall to %.2f mm", draftMfg.minWallThickness)
            ) { draftMfg.interLayerWall = draftMfg.minWallThickness }
        }
    }

    private func guardRow(
        _ message: String, fixTitle: String, fix: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
            Button(fixTitle, action: fix)
                .font(.caption2)
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    private func apply() {
        // Clamps on commit (so a stray 0 in the field can't slip into the
        // CSG) and migrates route endpoints off any footprint pin the new
        // values moved. Shared with the Edit-menu paste. Equal-value writes
        // are skipped so a no-op Apply doesn't dirty the document or push
        // an empty step onto the undo stack.
        ManufacturingActions.commit(draftMfg, to: &document)
        if scope == .full {
            let size = ManufacturingActions.sanitizedSize(draftBoard)
            if document.circuit.physical.boardOutline.size != size {
                document.circuit.physical.boardOutline.size = size
            }
        }
        // Store nil for "off" so a design that never flags itself stays
        // byte-identical to a v7 doc (and its content hash is unchanged).
        let skipEdgeWall: Bool? = draftSkipEdgeWall ? true : nil
        if document.circuit.skipEdgeWallDRC != skipEdgeWall {
            document.circuit.skipEdgeWallDRC = skipEdgeWall
        }
        // Sync the draft back from the clamped values so the UI mirrors what
        // actually landed.
        syncFromDocument(force: true)
    }

    private func revert() {
        syncFromDocument(force: true)
    }

    /// Forced (Apply/Revert/onAppear): draft := document. Unforced (the
    /// document changed underneath us): *rebase* — fields the user actually
    /// edited (draft ≠ baseline, per-field) keep their draft value, every
    /// other field follows the document immediately. The old behaviour
    /// (skip the whole sync while the draft differed from the *new*
    /// document) couldn't tell those apart, so any external write — a
    /// parameter paste, the envelope slider, ⌘Z — left the panel showing
    /// stale numbers that Apply would then write back over the change.
    private func syncFromDocument(force: Bool = false) {
        let mfg = document.circuit.manufacturing
        let size = document.circuit.physical.boardOutline.size
        let skipEdgeWall = document.circuit.skipEdgeWallDRC ?? false
        if force || !initialized {
            draftMfg = mfg
            draftBoard = size
            draftSkipEdgeWall = skipEdgeWall
            initialized = true
        } else {
            draftMfg = draftMfg.rebased(onto: mfg, baseline: baselineMfg)
            if draftBoard.width == baselineBoard.width {
                draftBoard.width = size.width
            }
            if draftBoard.height == baselineBoard.height {
                draftBoard.height = size.height
            }
            if draftSkipEdgeWall == baselineSkipEdgeWall {
                draftSkipEdgeWall = skipEdgeWall
            }
        }
        baselineMfg = mfg
        baselineBoard = size
        baselineSkipEdgeWall = skipEdgeWall
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

    /// Live readout of the stencil hole diameter a padding row produces —
    /// base bore + draft padding, mirroring PlateBuilder's stencil pass
    /// (via holes: channel diameter; screw holes: the 2.2 mm shaft
    /// clearance) — so the user sees the exported size, not just the delta.
    private func stencilHoleReadout(_ diameter: Double) -> some View {
        Text(String(format: "→ %.2f mm hole", diameter))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .trailing)
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
                .focused($fieldFocused)
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
