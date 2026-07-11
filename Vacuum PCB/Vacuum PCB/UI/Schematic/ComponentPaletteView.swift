import SwiftUI

/// Payload for dragging a palette entry onto the schematic canvas, shipped as a
/// short string through an `NSItemProvider` — mirrors the physical parking lot,
/// which ships a component UUID the same way. Only primitives are draggable;
/// library parts keep their click-to-add path (it runs assembly/layer checks).
enum SchematicPaletteDrag {
    case primitive(ComponentKind, PortDirection?)

    var dragString: String {
        switch self {
        case .primitive(let kind, let dir):
            return "prim:\(kind.rawValue):\(dir?.rawValue ?? "")"
        }
    }

    init?(dragString: String) {
        let parts = dragString.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.first == "prim", parts.count == 3,
              let kind = ComponentKind(rawValue: parts[1]) else { return nil }
        let dir = parts[2].isEmpty ? nil : PortDirection(rawValue: parts[2])
        self = .primitive(kind, dir)
    }
}

/// Component-spawning palette for the schematic. Lives in the document
/// inspector now (the right column), so the rows are laid out
/// horizontally — icon-letter on the left, name on the right — instead
/// of the vertical-strip form the leading-column version used.
/// Primitives are listed first; user-defined library parts (`.vpcb`
/// files in the parts folder) appear below a "Library" header.
/// A filter field at the top narrows both sections; Return adds the
/// single remaining match.
struct ComponentPaletteView: View {
    let onAdd: (ComponentKind, PortDirection?) -> Void
    let onAddLibraryPart: (PartsLibrary.Part) -> Void

    @ObservedObject private var library = PartsLibrary.shared
    @State private var filterText = ""

    /// One row of the fixed primitives section, in data form so the
    /// filter can run over it.
    private struct Primitive: Identifiable {
        let label: String
        let subtitle: String
        let kind: ComponentKind
        var dir: PortDirection? = nil
        var id: String { label }
    }

    private static let primitives: [Primitive] = [
        .init(label: "Q",   subtitle: "Transistor", kind: .transistor),
        .init(label: "R",   subtitle: "Resistor",   kind: .resistor),
        .init(label: "D",   subtitle: "LED",        kind: .led),
        .init(label: "VAC", subtitle: "Vacuum",     kind: .vacuumSource),
        .init(label: "ATM", subtitle: "Vent",       kind: .atmVent),
        .init(label: "IN",  subtitle: "Input",      kind: .port, dir: .input),
        .init(label: "OUT", subtitle: "Output",     kind: .port, dir: .output),
        .init(label: "J",   subtitle: "Connector",  kind: .connector),
    ]

    private var trimmedFilter: String {
        filterText.trimmingCharacters(in: .whitespaces)
    }

    private var visiblePrimitives: [Primitive] {
        guard !trimmedFilter.isEmpty else { return Self.primitives }
        return Self.primitives.filter {
            $0.subtitle.localizedCaseInsensitiveContains(trimmedFilter)
                || $0.label.localizedCaseInsensitiveContains(trimmedFilter)
        }
    }

    private var visibleParts: [PartsLibrary.Part] {
        guard !trimmedFilter.isEmpty else { return library.parts }
        return library.parts.filter {
            $0.displayName.localizedCaseInsensitiveContains(trimmedFilter)
        }
    }

    var body: some View {
        let primitives = visiblePrimitives
        let parts = visibleParts
        VStack(alignment: .leading, spacing: 6) {
            filterField

            if !primitives.isEmpty {
                sectionHeader("Add Component")
                ForEach(primitives) { p in
                    paletteButton(label: p.label, subtitle: p.subtitle, kind: p.kind, dir: p.dir)
                }
            }

            if !parts.isEmpty {
                if !primitives.isEmpty {
                    Divider().padding(.vertical, 4)
                }
                sectionHeader("Library")
                ForEach(parts) { part in
                    libraryButton(part: part)
                }
            }

            if primitives.isEmpty && parts.isEmpty {
                Text("No components match “\(trimmedFilter)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Filter", text: $filterText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit(addSingleMatch)
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #endif
            if !filterText.isEmpty {
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06))
        )
        .help("Type to filter the palette; press Return to add the only match")
        #if os(macOS)
        .onExitCommand { filterText = "" }
        #endif
    }

    /// Return in the filter field adds the one visible entry, making
    /// filter-then-Return a keyboard-only add path.
    private func addSingleMatch() {
        let primitives = visiblePrimitives
        let parts = visibleParts
        if let p = primitives.first, primitives.count == 1, parts.isEmpty {
            onAdd(p.kind, p.dir)
        } else if let part = parts.first, parts.count == 1, primitives.isEmpty {
            onAddLibraryPart(part)
        }
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
        // Click still adds at the spawn grid; drag drops it where you release
        // on the canvas (like the physical parking lot).
        .onDrag {
            NSItemProvider(object: SchematicPaletteDrag.primitive(kind, dir).dragString as NSString)
        }
        .help("Click to add, or drag onto the canvas to place")
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
