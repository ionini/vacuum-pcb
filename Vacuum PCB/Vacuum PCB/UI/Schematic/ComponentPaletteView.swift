import SwiftUI

/// Component-spawning palette for the schematic. Lives in the document
/// inspector now (the right column), so the rows are laid out
/// horizontally — icon-letter on the left, name on the right — instead
/// of the vertical-strip form the leading-column version used.
/// Primitives are listed first; user-defined library parts (`.vpcb`
/// files in the parts folder) appear below a "Library" header.
struct ComponentPaletteView: View {
    let onAdd: (ComponentKind, PortDirection?) -> Void
    let onAddLibraryPart: (PartsLibrary.Part) -> Void

    @ObservedObject private var library = PartsLibrary.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Add Component")
            paletteButton(label: "Q",   subtitle: "Transistor", kind: .transistor)
            paletteButton(label: "R",   subtitle: "Resistor",   kind: .resistor)
            paletteButton(label: "D",   subtitle: "LED",        kind: .led)
            paletteButton(label: "VAC", subtitle: "Vacuum",     kind: .vacuumSource)
            paletteButton(label: "ATM", subtitle: "Vent",       kind: .atmVent)
            paletteButton(label: "IN",  subtitle: "Input",      kind: .port, dir: .input)
            paletteButton(label: "OUT", subtitle: "Output",     kind: .port, dir: .output)
            paletteButton(label: "J",   subtitle: "Connector",  kind: .connector)

            if !library.parts.isEmpty {
                Divider().padding(.vertical, 4)
                sectionHeader("Library")
                ForEach(library.parts) { part in
                    libraryButton(part: part)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func paletteButton(
        label: String, subtitle: String, kind: ComponentKind, dir: PortDirection? = nil
    ) -> some View {
        Button {
            onAdd(kind, dir)
        } label: {
            HStack(spacing: 10) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 38, alignment: .center)
                Text(subtitle)
                    .font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.22))
            )
        }
        .buttonStyle(.plain)
    }

    private func libraryButton(part: PartsLibrary.Part) -> some View {
        Button {
            onAddLibraryPart(part)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "puzzlepiece.fill")
                    .foregroundStyle(Color.teal)
                    .frame(width: 38, alignment: .center)
                VStack(alignment: .leading, spacing: 0) {
                    Text(part.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(part.pins.count) pins")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.teal.opacity(0.45))
            )
        }
        .buttonStyle(.plain)
        .help(part.filename)
    }
}
