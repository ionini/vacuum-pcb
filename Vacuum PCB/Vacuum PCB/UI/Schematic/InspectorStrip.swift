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
        switch selection {
        case .component(let id):
            if let component = component(id) {
                componentInspector(component)
            }
        case .net(let id):
            if let net = net(id) {
                netInspector(net)
            }
        case .pin, .none:
            EmptyView()
        }
    }

    private var hint: some View {
        let text: String = {
            switch selection {
            case .none:
                return "Click a palette button to add. Click pin → pin to connect. ⌫ to delete."
            case .component:
                return "Double-click label to rename. Drag to move. ⌫ to delete."
            case .net:
                return "⌫ to delete. Click pin pair to extend or break."
            case .pin:
                return "Click another pin to connect."
            }
        }()
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
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }
            if c.kind == .port {
                Picker("Direction", selection: portDirectionBinding(c)) {
                    Text("Input").tag(Optional(PortDirection.input))
                    Text("Output").tag(Optional(PortDirection.output))
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }
        }
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
        }
    }
}
