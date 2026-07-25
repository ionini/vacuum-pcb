import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Bottom strip showing context-aware controls for whatever is currently selected.
/// Resistor → S/M/L picker. Port → input/output toggle. Component → rename field.
/// Net → label rename. Connector / subpart with sockets → mating controls.
/// Nothing selected → instructions.
struct InspectorStrip: View {
    @Binding var document: VPCBDocument
    @Binding var selection: SchematicSelection
    /// Presentation flag for the connector pin-names editor popover.
    @State private var showingPinNames = false
    /// Observed so the subpart version-pin badge flips to "Library has
    /// changes" the moment the library re-indexes — e.g. right after the
    /// part's own tab is saved — instead of waiting for an unrelated
    /// re-render.
    @ObservedObject private var library = PartsLibrary.shared
    #if canImport(AppKit)
    /// Opens a library `.vpcb` in the DocumentGroup (used by the subpart
    /// "Open in Tab" button). The environment action is macOS-only, which
    /// is fine — window tabs are a Mac concept; iPad reaches part files
    /// through the document browser.
    @Environment(\.openDocument) private var openDocument
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Keep the strip a stable height. When the window is wide enough,
            // show the controls with the hint pinned right. When it isn't, put
            // everything on one horizontally-scrollable line instead of letting
            // the hint wrap onto extra lines and grow the strip (worst for the
            // connector, whose control row is the widest).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    content
                    Spacer(minLength: 8)
                    hint
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        content
                        hint
                    }
                }
            }
            matingRows
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .frame(minHeight: 44)
    }

    /// Per-endpoint mating controls. One row per top-level connector or
    /// subpart socket on the currently selected component. Hidden when the
    /// selection has no matable endpoints.
    @ViewBuilder private var matingRows: some View {
        if let only = selection.singleComponent, let c = component(only) {
            if c.kind == .connector {
                MatingRow(
                    endpoint: .topLevel(componentId: c.id),
                    headline: c.label,
                    document: $document
                )
            } else if c.kind == .subpart {
                let sockets = subpartSockets(c)
                ForEach(sockets, id: \.connectorId) { socket in
                    MatingRow(
                        endpoint: .subpartSocket(subpartId: c.id, connectorId: socket.connectorId),
                        headline: "\(c.label).\(socket.label)",
                        document: $document
                    )
                }
            }
        }
    }

    private func subpartSockets(_ c: Component) -> [BoundarySocket] {
        c.resolvedPart(snapshots: document.circuit.librarySnapshots)?.sockets ?? []
    }

    @ViewBuilder private var content: some View {
        // Component-side controls only make sense for exactly one selected
        // component (S/M/L picker, port direction). The same goes for net
        // label editing. In multi-selection we just show the count below in
        // the hint.
        if let only = selection.singleComponent, let c = component(only) {
            componentInspector(c)
        } else if let netId = selection.net, let n = net(netId) {
            netInspector(n)
        } else {
            EmptyView()
        }
    }

    private var hint: some View {
        // Strip the cursor/keyboard idioms (`⌫`, `⌘-click`, "Double-click")
        // out of the hint on iPad, where the only way to delete is the
        // editor toolbars/menus and there's no Cmd-click. Leaves a slightly
        // tighter sentence rather than misleading the user.
        let touch = InputPlatform.isTouch
        let text: String
        if selection.isEmpty {
            text = touch
                ? "Tap a palette button to add. Drag empty canvas to box-select."
                : "Click a palette button to add. Drag empty canvas to box-select. ⌫ to delete."
        } else if selection.net != nil {
            text = touch
                ? "Tap a pin pair to extend or break this net."
                : "⌫ to delete this net. Click pin pair to extend or break it."
        } else if selection.singleComponent != nil {
            text = touch
                ? "Drag to move. Double-tap label to rename."
                : "Double-click label to rename. Drag to move. ⌘-click to multi-select. ⌫ to delete."
        } else {
            text = touch
                ? "\(selection.components.count) components selected. Drag any to move them together."
                : "\(selection.components.count) components selected. Drag any to move them together. ⌫ to delete."
        }
        return Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            // Keep the hint on one line — without this it wraps as the window
            // narrows, growing the whole strip's height. Lowest priority so it
            // truncates before the controls give up any width.
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(-1)
    }

    // MARK: - Selected component

    private func componentInspector(_ c: Component) -> some View {
        HStack(spacing: 10) {
            Text(c.label).font(.headline).lineLimit(1).fixedSize()
            Text("(\(c.kind.displayName))").foregroundStyle(.secondary).lineLimit(1).fixedSize()
            if c.kind == .resistor {
                Picker("Size", selection: resistorSizeBinding(c)) {
                    Text("S").tag(ResistorSize.small)
                    Text("M").tag(ResistorSize.medium)
                    Text("L").tag(ResistorSize.large)
                    Text("XL").tag(ResistorSize.extraLarge)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if c.kind == .port {
                Picker("Direction", selection: portDirectionBinding(c)) {
                    Text("Input").tag(Optional(PortDirection.input))
                    Text("Output").tag(Optional(PortDirection.output))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if c.kind == .connector {
                Stepper(
                    value: connectorPinCountBinding(c),
                    in: 1...32
                ) {
                    Text("\(c.connectorPinCount ?? 1) pin\((c.connectorPinCount ?? 1) == 1 ? "" : "s")")
                        .font(.system(size: 12))
                }
                .fixedSize()
                let maxScrews = ComponentKind.connectorMaxScrewCount(pinCount: c.connectorPinCount ?? 1)
                let debugPorts = c.connectorDebugPorts ?? false
                Stepper(
                    value: connectorScrewCountBinding(c),
                    in: ComponentKind.connectorMinScrewCount...maxScrews
                ) {
                    let s = c.connectorScrewCount ?? ComponentKind.connectorMinScrewCount
                    Text("\(s) screw\(s == 1 ? "" : "s")")
                        .font(.system(size: 12))
                        .foregroundStyle(debugPorts ? .secondary : .primary)
                }
                .fixedSize()
                .disabled(debugPorts)
                .help("Clamp screws. 2 keeps one at each end (the default). 3+ split the pins into even groups with a screw between each. Mating halves must use the same screw count.")
                Toggle(isOn: connectorDebugPortsBinding(c)) {
                    Text("Debug ports")
                        .font(.system(size: 12))
                }
                .checklistToggleStyle()
                .fixedSize()
                .help("Print this connector as a row of plain tube sockets \(Int(ComponentKind.connectorDebugPortPitch)) mm apart instead of the mating protrusion — for bench-driving the board on its own. No protrusion, no screws; nets, simulation, and matings are unchanged, so it still pairs with a normal half. Pins sit at a different pitch, so routes into the connector need re-drawing after toggling. In the physical view, press F over a socket to move it to another layer (each socket is independent; choices are remembered when you toggle back).")
                Picker("Role", selection: connectorRoleBinding(c)) {
                    Text("Carries silicone").tag(ConnectorRole.bottomExtend)
                    Text("Mates with silicone").tag(ConnectorRole.topExtend)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Picker("Signal", selection: connectorSignalBinding(c)) {
                    Text("In").tag(ConnectorSignal.input)
                    Text("Out").tag(ConnectorSignal.output)
                    Text("Bus").tag(ConnectorSignal.bidirectional)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Electrical mode. Bus = bidirectional: each pin is a probe plus an optional soft drive you can assert during standalone simulation.")
                Button("Pin names…") { showingPinNames = true }
                    .controlSize(.small)
                    .popover(isPresented: $showingPinNames, arrowEdge: .bottom) {
                        pinNamesEditor(c)
                    }
            }
            if c.kind == .subpart {
                subpartLibrarySync(c)
            }
        }
    }

    /// Subpart version-pin status + manual "Update from Library" button. The
    /// pinned snapshot is what every renderer / CAD pass reads; this control
    /// is the only way edits in the parts folder reach a placed instance.
    @ViewBuilder
    private func subpartLibrarySync(_ c: Component) -> some View {
        let live = c.partRef.flatMap { library.part(named: $0) }
        // Compare deep behavioural state — transitive edits (a dep of a
        // dep changed) need to surface as "out of date" too. The shallow
        // `contentHash` strips partRefHash for snapshot-key stability and
        // would miss this entirely.
        let liveDeep = live?.document.effectiveHash()
        let pinnedDeep = c.partRefHash.flatMap { document.circuit.librarySnapshots[$0]?.effectiveHash() }
        let outOfDate = liveDeep != nil && liveDeep != pinnedDeep
        Divider().frame(height: 18)
        if live == nil {
            Label("Library file missing", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        } else if outOfDate {
            Label("Library has changes", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
                .font(.caption)
            Button("Update from Library") { updateSubpartFromLibrary(c) }
                .controlSize(.small)
        } else {
            Label("Up to date", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        #if canImport(AppKit)
        if live != nil {
            Button {
                openPartFile(c)
            } label: {
                Label("Open in Tab", systemImage: "arrow.up.forward.square")
            }
            .controlSize(.small)
            .help("Open this part's library file for editing. Edits there reach this instance via Update from Library.")
        }
        #endif
    }

    #if canImport(AppKit)
    /// Open the subpart's backing library file as a tab of the window the
    /// button was clicked in. Shared re-homing logic lives in `SubpartTabs`.
    private func openPartFile(_ c: Component) {
        guard let filename = c.partRef else { return }
        let host = NSApp.keyWindow
        Task { @MainActor in
            await SubpartTabs.open(filename: filename, host: host, openDocument: openDocument)
        }
    }
    #endif

    private func updateSubpartFromLibrary(_ c: Component) {
        guard let filename = c.partRef,
              let live = PartsLibrary.shared.part(named: filename),
              let i = document.circuit.logic.components.firstIndex(where: { $0.id == c.id })
        else { return }
        let newHash = live.document.contentHash()
        // Unconditional replace: the structural `contentHash` key may
        // collide with an existing snapshot (transitive-only change), but
        // the live doc's inner tree is what we want stored. Conditional
        // store would leave the stale snapshot in place.
        document.circuit.librarySnapshots[newHash] = live.document
        document.circuit.logic.components[i].partRefHash = newHash
    }

    private func resistorSizeBinding(_ c: Component) -> Binding<ResistorSize> {
        Binding(
            get: { c.resistorSize ?? .medium },
            set: { newSize in
                guard let i = document.circuit.logic.components.firstIndex(where: { $0.id == c.id }) else { return }
                document.circuit.logic.components[i].resistorSize = newSize
            }
        )
    }

    private func portDirectionBinding(_ c: Component) -> Binding<PortDirection?> {
        Binding(
            get: { c.portDirection },
            set: { newDir in
                guard let i = document.circuit.logic.components.firstIndex(where: { $0.id == c.id }) else { return }
                document.circuit.logic.components[i].portDirection = newDir
            }
        )
    }

    private func connectorPinCountBinding(_ c: Component) -> Binding<Int> {
        Binding(
            get: { c.connectorPinCount ?? 1 },
            set: { newCount in
                let clamped = max(1, newCount)
                guard let i = document.circuit.logic.components.firstIndex(where: { $0.id == c.id }) else { return }
                let oldCount = document.circuit.logic.components[i].connectorPinCount ?? 1
                document.circuit.logic.components[i].connectorPinCount = clamped
                // A connector needs one pin per inter-screw group, so fewer
                // pins can cap the screw count. Clamp it down rather than leave
                // an impossible layout (the geometry would clamp it anyway).
                let maxScrews = ComponentKind.connectorMaxScrewCount(pinCount: clamped)
                if let s = document.circuit.logic.components[i].connectorScrewCount, s > maxScrews {
                    document.circuit.logic.components[i].connectorScrewCount =
                        maxScrews == ComponentKind.connectorMinScrewCount ? nil : maxScrews
                }
                // Drop net memberships for any pin whose index exceeds the
                // new count — otherwise stepping down leaves orphan PinRefs
                // pointing at pins that no longer exist in the footprint.
                if clamped < oldCount {
                    // Trim names for the now-gone pins so they don't resurrect
                    // if the user steps the count back up later.
                    if var names = document.circuit.logic.components[i].connectorPinNames {
                        if names.count > clamped { names.removeLast(names.count - clamped) }
                        document.circuit.logic.components[i].connectorPinNames =
                            names.allSatisfy(\.isEmpty) ? nil : names
                    }
                    // Same for per-socket debug layers: drop entries for
                    // pins that no longer exist (normalising to nil when
                    // everything left sits on the role default).
                    if var layers = document.circuit.logic.components[i].connectorDebugPortLayers {
                        if layers.count > clamped { layers.removeLast(layers.count - clamped) }
                        let fallback = ComponentKind.connectorDebugPortDefaultLayer(
                            role: document.circuit.logic.components[i].connectorRole ?? .bottomExtend
                        )
                        document.circuit.logic.components[i].connectorDebugPortLayers =
                            layers.allSatisfy { $0 == fallback } ? nil : layers
                    }
                    for netIdx in document.circuit.logic.nets.indices {
                        document.circuit.logic.nets[netIdx].pins.removeAll { pin in
                            guard pin.componentId == c.id,
                                  let n = Int(pin.pinKey)
                            else { return false }
                            return n > clamped
                        }
                    }
                    document.circuit.logic.nets.removeAll { $0.pins.count < 2 }
                }
            }
        )
    }

    private func connectorDebugPortsBinding(_ c: Component) -> Binding<Bool> {
        Binding(
            get: { c.connectorDebugPorts ?? false },
            set: { on in
                guard let i = document.circuit.logic.components.firstIndex(where: { $0.id == c.id }) else { return }
                // Store nil for the default (normal print) so untouched
                // connectors stay byte-identical on save.
                document.circuit.logic.components[i].connectorDebugPorts = on ? true : nil
            }
        )
    }

    private func connectorScrewCountBinding(_ c: Component) -> Binding<Int> {
        Binding(
            get: { c.connectorScrewCount ?? ComponentKind.connectorMinScrewCount },
            set: { newCount in
                guard let i = document.circuit.logic.components.firstIndex(where: { $0.id == c.id }) else { return }
                let pinCount = document.circuit.logic.components[i].connectorPinCount ?? 1
                let clamped = min(max(ComponentKind.connectorMinScrewCount, newCount),
                                  ComponentKind.connectorMaxScrewCount(pinCount: pinCount))
                // Store nil for the default two-end-cap layout so connectors
                // the user never re-screwed stay byte-identical on save.
                document.circuit.logic.components[i].connectorScrewCount =
                    clamped == ComponentKind.connectorMinScrewCount ? nil : clamped
            }
        )
    }

    private func connectorRoleBinding(_ c: Component) -> Binding<ConnectorRole> {
        Binding(
            get: { c.connectorRole ?? .bottomExtend },
            set: { newRole in
                guard let i = document.circuit.logic.components.firstIndex(where: { $0.id == c.id }) else { return }
                document.circuit.logic.components[i].connectorRole = newRole
                // Connector pin layer follows the role: `.bottomExtend`
                // pins live on the bottom plate, `.topExtend` on the top.
                // Sync `placement.layer` so the existing pin-resolution
                // path (`Placement.resolvedPlate(of:)`) lands routes on
                // the right plate after the toggle.
                if let pIdx = document.circuit.physical.placements.firstIndex(where: { $0.componentId == c.id }) {
                    document.circuit.physical.placements[pIdx].layer = newRole == .bottomExtend ? .bottom : .top
                }
            }
        )
    }

    private func connectorSignalBinding(_ c: Component) -> Binding<ConnectorSignal> {
        Binding(
            // Resolve through the role-derived fallback so a pre-bus connector
            // shows the segment matching its old behaviour rather than an
            // empty selection.
            get: { c.resolvedConnectorSignal },
            set: { newSignal in
                guard let i = document.circuit.logic.components.firstIndex(where: { $0.id == c.id }) else { return }
                document.circuit.logic.components[i].connectorSignal = newSignal
            }
        )
    }

    /// Editable list of pin names for a connector. One row per pin; a blank
    /// field falls back to the pin number everywhere the name is shown.
    private func pinNamesEditor(_ c: Component) -> some View {
        let count = max(1, c.connectorPinCount ?? 1)
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(c.label) pin names").font(.headline)
            Text("Blank uses the pin number. Names appear on the schematic, the physical view, the simulator, and when this part is imported into another design.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(0..<count), id: \.self) { i in
                        HStack(spacing: 8) {
                            Text("\(i + 1)")
                                .font(.system(size: 11, weight: .medium).monospaced())
                                .foregroundStyle(.secondary)
                                .frame(width: 22, alignment: .trailing)
                            TextField("pin \(i + 1)", text: connectorPinNameBinding(c, index: i))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 300)
        }
        .padding(12)
        .frame(width: 240)
    }

    /// Two-way binding for one pin's name. Reads from the live document so the
    /// fields stay correct if the pin count changes while the popover is open;
    /// writes pad the array up to the current pin count and collapse an
    /// all-blank array back to nil so an unnamed connector stays byte-stable.
    private func connectorPinNameBinding(_ c: Component, index: Int) -> Binding<String> {
        Binding(
            get: {
                let names = c.connectorPinNames ?? []
                return index < names.count ? names[index] : ""
            },
            set: { newName in
                guard let i = document.circuit.logic.components.firstIndex(where: { $0.id == c.id }) else { return }
                let count = max(1, document.circuit.logic.components[i].connectorPinCount ?? 1)
                var names = document.circuit.logic.components[i].connectorPinNames ?? []
                if names.count < count {
                    names.append(contentsOf: Array(repeating: "", count: count - names.count))
                }
                guard index < names.count else { return }
                names[index] = newName
                document.circuit.logic.components[i].connectorPinNames =
                    names.allSatisfy(\.isEmpty) ? nil : names
            }
        )
    }

    // MARK: - Selected net

    private func netInspector(_ n: Net) -> some View {
        HStack(spacing: 10) {
            Text("Net").foregroundStyle(.secondary)
            TextField("Label", text: netLabelBinding(n))
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
            Text("\(n.pins.count) pins").foregroundStyle(.secondary)
        }
    }

    private func netLabelBinding(_ n: Net) -> Binding<String> {
        Binding(
            get: { n.label },
            set: { newLabel in
                let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                guard let i = document.circuit.logic.nets.firstIndex(where: { $0.id == n.id }) else { return }
                document.circuit.logic.nets[i].label = trimmed
            }
        )
    }

    // MARK: - Lookups

    private func component(_ id: UUID) -> Component? {
        document.circuit.logic.components.first(where: { $0.id == id })
    }

    private func net(_ id: UUID) -> Net? {
        document.circuit.logic.nets.first(where: { $0.id == id })
    }
}

/// One inspector row that surfaces an endpoint's current mate and a
/// picker for compatible peers. Renders as: `"<label>  Mate to ▼"` (when
/// unmated) or `"<label>  Mated to <peer>  [Unmate]"` (when mated).
struct MatingRow: View {
    let endpoint: ConnectorEndpoint
    let headline: String
    @Binding var document: VPCBDocument

    var body: some View {
        let current = MatingActions.mating(for: endpoint, in: document.circuit)
        HStack(spacing: 8) {
            Image(systemName: "link")
                .foregroundStyle(.indigo)
                .font(.caption)
            Text(headline)
                .font(.caption.bold())
                .foregroundStyle(.indigo)
                .lineLimit(1)
                .fixedSize()
            if let mate = current,
               let peer = MatingActions.otherEndpoint(of: mate, from: endpoint),
               let peerLabel = MatingActions.label(for: peer, in: document.circuit) {
                Text("Mated to")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Text(peerLabel)
                    .font(.caption.bold())
                    .lineLimit(1)
                    .truncationMode(.tail)
                Button("Unmate") {
                    MatingActions.unmate(endpoint, in: &document.circuit)
                }
                .controlSize(.small)
                if let mineS = MatingActions.screwCount(for: endpoint, in: document.circuit),
                   let peerS = MatingActions.screwCount(for: peer, in: document.circuit),
                   mineS != peerS {
                    Label("Screw counts differ (\(mineS) vs \(peerS)) — bolts won't line up",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                }
            } else {
                let peers = MatingActions.compatiblePeers(for: endpoint, in: document.circuit)
                if peers.isEmpty {
                    Text("No compatible peer (need opposite role + matching pin count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                } else {
                    Menu {
                        ForEach(peers, id: \.0) { peer in
                            Button(peer.1) {
                                MatingActions.mate(endpoint, peer.0, in: &document.circuit)
                            }
                        }
                    } label: {
                        Label("Mate to…", systemImage: "chevron.down.circle")
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
    }
}

/// Document-level helpers for creating, removing, and listing matings.
/// Free functions kept off `CircuitDocument` so the model file stays focused
/// on persistence — these are UI-driven actions and lookups.
enum MatingActions {
    static func mating(for endpoint: ConnectorEndpoint, in circuit: CircuitDocument) -> Mating? {
        circuit.logic.matings.first(where: { $0.a == endpoint || $0.b == endpoint })
    }

    static func otherEndpoint(of mating: Mating, from endpoint: ConnectorEndpoint) -> ConnectorEndpoint? {
        if mating.a == endpoint { return mating.b }
        if mating.b == endpoint { return mating.a }
        return nil
    }

    /// User-visible label for an endpoint. Top-level connectors carry
    /// their own label; subpart sockets prefix with the subpart's label
    /// (e.g., "U1.J2") so the picker disambiguates across instances.
    static func label(for endpoint: ConnectorEndpoint, in circuit: CircuitDocument) -> String? {
        switch endpoint {
        case .topLevel(let id):
            return circuit.logic.components.first(where: { $0.id == id })?.label
        case .subpartSocket(let subpartId, let connectorId):
            guard let subpart = circuit.logic.components.first(where: { $0.id == subpartId }),
                  let part = subpart.resolvedPart(snapshots: circuit.librarySnapshots),
                  let comp = part.document.logic.components.first(where: { $0.id == connectorId })
            else { return nil }
            return "\(subpart.label).\(comp.label)"
        }
    }

    private static func resolveConnector(_ endpoint: ConnectorEndpoint, in circuit: CircuitDocument) -> Component? {
        switch endpoint {
        case .topLevel(let id):
            return circuit.logic.components.first(where: { $0.id == id })
        case .subpartSocket(let subpartId, let connectorId):
            guard let subpart = circuit.logic.components.first(where: { $0.id == subpartId }),
                  let part = subpart.resolvedPart(snapshots: circuit.librarySnapshots)
            else { return nil }
            return part.document.logic.components.first(where: { $0.id == connectorId })
        }
    }

    /// Clamp-screw count for an endpoint's connector (`?? 2` applied), or nil
    /// when the endpoint can't be resolved.
    static func screwCount(for endpoint: ConnectorEndpoint, in circuit: CircuitDocument) -> Int? {
        guard let c = resolveConnector(endpoint, in: circuit) else { return nil }
        return c.connectorScrewCount ?? ComponentKind.connectorMinScrewCount
    }

    /// Endpoints compatible with the given one: opposite role, matching
    /// pin count, not the same endpoint, and either un-mated or already
    /// mated to *this* endpoint (so the picker shows the current mate as
    /// "selected").
    static func compatiblePeers(
        for endpoint: ConnectorEndpoint,
        in circuit: CircuitDocument
    ) -> [(ConnectorEndpoint, String)] {
        guard let mine = resolveConnector(endpoint, in: circuit),
              let myRole = mine.connectorRole,
              let myCount = mine.connectorPinCount
        else { return [] }
        let myScrews = mine.connectorScrewCount ?? ComponentKind.connectorMinScrewCount
        let myMatingId = mating(for: endpoint, in: circuit)?.id
        var candidates: [(ConnectorEndpoint, String)] = []
        // Screw count is a *soft* match: a mismatched peer still mates (the
        // pins line up) but the menu flags it so the user sees the bolt
        // pattern won't, matching the DRC warning.
        func peerLabel(_ base: String, theirScrews: Int) -> String {
            theirScrews == myScrews ? base : "\(base)  ⚠ \(theirScrews) screws"
        }
        // Top-level connector candidates.
        for c in circuit.logic.components where c.kind == .connector {
            let other: ConnectorEndpoint = .topLevel(componentId: c.id)
            if other == endpoint { continue }
            guard c.connectorRole == myRole.opposite,
                  c.connectorPinCount == myCount
            else { continue }
            if let existing = mating(for: other, in: circuit), existing.id != myMatingId { continue }
            candidates.append((other, peerLabel(c.label,
                theirScrews: c.connectorScrewCount ?? ComponentKind.connectorMinScrewCount)))
        }
        // Subpart socket candidates.
        for c in circuit.logic.components where c.kind == .subpart {
            guard let part = c.resolvedPart(snapshots: circuit.librarySnapshots) else { continue }
            for socket in part.sockets {
                let other: ConnectorEndpoint = .subpartSocket(subpartId: c.id, connectorId: socket.connectorId)
                if other == endpoint { continue }
                guard socket.role == myRole.opposite,
                      socket.pinCount == myCount
                else { continue }
                if let existing = mating(for: other, in: circuit), existing.id != myMatingId { continue }
                candidates.append((other, peerLabel("\(c.label).\(socket.label)",
                    theirScrews: socket.screwCount)))
            }
        }
        candidates.sort { $0.1 < $1.1 }
        return candidates
    }

    /// Create or replace a mating between `a` and `b`. Existing matings
    /// that involve either endpoint are removed first so the one-mating-
    /// per-connector invariant is preserved.
    static func mate(_ a: ConnectorEndpoint, _ b: ConnectorEndpoint, in circuit: inout CircuitDocument) {
        guard a != b else { return }
        circuit.logic.matings.removeAll {
            $0.a == a || $0.b == a || $0.a == b || $0.b == b
        }
        circuit.logic.matings.append(Mating(a: a, b: b))
    }

    static func unmate(_ endpoint: ConnectorEndpoint, in circuit: inout CircuitDocument) {
        circuit.logic.matings.removeAll { $0.a == endpoint || $0.b == endpoint }
    }
}

extension ConnectorRole {
    /// The role this half mates against: `bottomExtend` ↔ `topExtend`.
    var opposite: ConnectorRole {
        switch self {
        case .bottomExtend: return .topExtend
        case .topExtend: return .bottomExtend
        }
    }
}

extension ComponentKind {
    var displayName: String {
        switch self {
        case .transistor:    return "Transistor"
        case .resistor:      return "Resistor"
        case .vacuumSource:  return "Vacuum Source"
        case .atmVent:       return "Atm Vent"
        case .port:          return "Port"
        case .subpart:       return "Subpart"
        case .screw:         return "Screw"
        case .led:           return "LED"
        case .connector:     return "Connector"
        }
    }
}
