import SwiftUI

/// Bottom strip showing context-aware controls for whatever is currently selected.
/// Resistor → S/M/L picker. Port → input/output toggle. Component → rename field.
/// Net → label rename. Nothing selected → instructions.
struct InspectorStrip: View {
    @Binding var document: VPCBDocument
    @Binding var selection: SchematicSelection

    var body: some View {
        HStack(spacing: 12) {
            content
            Spacer()
            hint
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .frame(minHeight: 44)
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
        let text: String
        if selection.isEmpty {
            text = "Click a palette button to add. Drag empty canvas to box-select. ⌫ to delete."
        } else if selection.net != nil {
            text = "⌫ to delete this net. Click pin pair to extend or break it."
        } else if selection.singleComponent != nil {
            text = "Double-click label to rename. Drag to move. ⌘-click to multi-select. ⌫ to delete."
        } else {
            text = "\(selection.components.count) components selected. Drag any to move them together. ⌫ to delete."
        }
        return Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Selected component

    private func componentInspector(_ c: Component) -> some View {
        HStack(spacing: 10) {
            Text(c.label).font(.headline)
            Text("(\(c.kind.displayName))").foregroundStyle(.secondary)
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
        let live = c.partRef.flatMap { PartsLibrary.shared.part(named: $0) }
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
    }

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
        }
    }
}
