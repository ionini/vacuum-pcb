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
    @Binding var document: VPCBDocument

    @State private var draftMfg: ManufacturingConstants = .defaults
    @State private var draftBoard: Size = Size(width: 50, height: 30)
    @State private var initialized = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manufacturing").font(.title3).bold()

            group("Board") {
                row("Width",  $draftBoard.width)
                row("Height", $draftBoard.height)
            }

            group("Plates") {
                row("Plate thickness (single-layer)", $draftMfg.plateThickness)
                row("Silicone thickness",             $draftMfg.siliconeThickness)
                row("Inter-layer wall",               $draftMfg.interLayerWall)
                Text("Multi-layer plates: plate thickness above is the depth-0 plate height. Each extra channel layer adds channelDiameter + inter-layer wall to that plate's height.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            group("Channels") {
                row("Channel diameter",          $draftMfg.channelDiameter)
                row("Resistor bore diameter",    $draftMfg.resistorChannelDiameter)
                row("Port bore diameter",        $draftMfg.portBoreDiameter)
                row("Min channel spacing (DRC)", $draftMfg.minChannelSpacing)
            }

            group("Transistor gate") {
                row("Dome diameter",        $draftMfg.dimpleDiameter)
                row("Dome sphere offset",   $draftMfg.dimpleSphereOffset)
                Text("Dome is a sphere of the diameter above, centred this far into the silicone gap from the plate face.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            group("Transistor source/drain pads") {
                row("Pads diameter",        $draftMfg.padsDiameter)
                row("Pads separation",      $draftMfg.padsSeparation)
                row("Tube offset (centre)", $draftMfg.padsOffset)
                row("Edge fillet radius",   $draftMfg.padsFilletRadius)
                Text("Two cap-shaped cavities on the opposite plate, split by a strip of this width along the source-drain axis. Tube offset is the distance from the gate centre to each drop-bore tube. Fillet radius rounds the sharp edge between the spherical surface and the flat face (set 0 for a sharp corner).")
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
        document.circuit.manufacturing = sanitized(draftMfg)
        document.circuit.physical.boardOutline.size = sanitizedSize(draftBoard)
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
            interLayerWall: max(0.1, m.interLayerWall)
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
        HStack(spacing: 8) {
            Text(label).font(.caption)
            Spacer(minLength: 4)
            // NumberFormatter (vs. the newer .number FormatStyle) parses
            // partial decimal input more reliably — e.g. SwiftUI's FormatStyle
            // path was rejecting "0.5" entered into a field whose current
            // value formatted as "1" with fractionLength(0...3).
            TextField("", value: value, formatter: Self.mmFormatter)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
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
