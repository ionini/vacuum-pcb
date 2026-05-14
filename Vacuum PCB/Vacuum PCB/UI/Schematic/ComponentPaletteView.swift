import SwiftUI

/// Vertical strip of buttons that spawn a new component on the schematic.
struct ComponentPaletteView: View {
    let onAdd: (ComponentKind, PortDirection?) -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text("Add")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            paletteButton(label: "Q", subtitle: "Transistor", kind: .transistor)
            paletteButton(label: "R", subtitle: "Resistor",   kind: .resistor)
            paletteButton(label: "VAC", subtitle: "Vacuum",   kind: .vacuumSource)
            paletteButton(label: "ATM", subtitle: "Vent",     kind: .atmVent)
            paletteButton(label: "IN", subtitle: "Input",     kind: .port, dir: .input)
            paletteButton(label: "OUT", subtitle: "Output",   kind: .port, dir: .output)

            Spacer()
        }
        .frame(width: 80)
        .padding(.horizontal, 6)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func paletteButton(
        label: String, subtitle: String, kind: ComponentKind, dir: PortDirection? = nil
    ) -> some View {
        Button {
            onAdd(kind, dir)
        } label: {
            VStack(spacing: 1) {
                Text(label).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 38)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.25))
            )
        }
        .buttonStyle(.plain)
    }
}
