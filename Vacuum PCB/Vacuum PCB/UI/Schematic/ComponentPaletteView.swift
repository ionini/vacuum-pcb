import SwiftUI

/// Vertical strip of buttons that spawn a new component on the schematic.
/// Primitives sit at the top; user-defined library parts (`.vpcb` files in
/// the parts folder) appear below a "Library" header.
struct ComponentPaletteView: View {
    let onAdd: (ComponentKind, PortDirection?) -> Void
    let onAddLibraryPart: (PartsLibrary.Part) -> Void

    @ObservedObject private var library = PartsLibrary.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                Text("Add")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                paletteButton(label: "Q", subtitle: "Transistor", kind: .transistor)
                paletteButton(label: "R", subtitle: "Resistor", kind: .resistor)
                paletteButton(label: "D", subtitle: "LED", kind: .led)
                paletteButton(label: "VAC", subtitle: "Vacuum", kind: .vacuumSource)
                paletteButton(label: "ATM", subtitle: "Vent", kind: .atmVent)
                paletteButton(label: "IN", subtitle: "Input", kind: .port, dir: .input)
                paletteButton(label: "OUT", subtitle: "Output", kind: .port, dir: .output)

                if !library.parts.isEmpty {
                    Divider().padding(.vertical, 4)
                    Text("Library")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ForEach(library.parts) { part in
                        libraryButton(part: part)
                    }
                }

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 6)
        }
        .frame(width: 80)
        .background(Color.paneBackground)
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

    private func libraryButton(part: PartsLibrary.Part) -> some View {
        Button {
            onAddLibraryPart(part)
        } label: {
            VStack(spacing: 1) {
                Text(part.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(part.pins.count) pins")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 38)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.teal.opacity(0.55))
            )
        }
        .buttonStyle(.plain)
        .help(part.filename)
    }
}
