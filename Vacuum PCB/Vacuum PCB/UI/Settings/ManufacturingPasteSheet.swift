import SwiftUI

/// A pending "paste manufacturing parameters" confirmation. Identifiable so
/// it can drive a `.sheet(item:)` — a fresh id each time means re-pasting the
/// same payload re-presents the sheet.
struct ManufacturingPasteRequest: Identifiable {
    let id = UUID()
    let incoming: ManufacturingConstants
    let sourceName: String?

    /// Builds a request from whatever the clipboard currently holds, or nil
    /// if nothing has been copied yet.
    static func fromClipboard() -> ManufacturingPasteRequest? {
        let clipboard = ManufacturingClipboard.shared
        guard let payload = clipboard.payload else { return nil }
        return ManufacturingPasteRequest(incoming: payload, sourceName: clipboard.sourceName)
    }
}

extension View {
    /// Hosts the paste confirmation sheet. Setting `request` presents it;
    /// Apply commits the (possibly partial) selection through
    /// `ManufacturingActions.commit`, so the paste clamps and migrates route
    /// endpoints exactly like the inspector's Apply button.
    func manufacturingPasteConfirmation(
        request: Binding<ManufacturingPasteRequest?>,
        document: Binding<VPCBDocument>
    ) -> some View {
        sheet(item: request) { pending in
            ManufacturingPasteSheet(
                current: document.wrappedValue.circuit.manufacturing,
                incoming: pending.incoming,
                sourceName: pending.sourceName,
                onApply: { fields in
                    // Merge against the document as it stands *now*, not the
                    // snapshot the sheet opened with, so an unchecked row can
                    // never write back a stale value.
                    let merged = document.wrappedValue.circuit.manufacturing
                        .merging(pending.incoming, fields: fields)
                    ManufacturingActions.commit(merged, to: &document.wrappedValue)
                })
        }
    }
}

/// Confirmation table for a manufacturing-parameter paste: every constant
/// with its current and incoming value side by side, a per-row checkbox
/// (checked by default for everything that differs), and Apply / Cancel.
///
/// Only the checked rows are written; the rest keep this document's values.
/// Board size and the design-rule flags are deliberately *not* part of the
/// payload — they describe this board, not how it's manufactured.
struct ManufacturingPasteSheet: View {
    let current: ManufacturingConstants
    let incoming: ManufacturingConstants
    let sourceName: String?
    /// Called with the ids of the checked (and actually differing) fields.
    let onApply: (Set<String>) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selected: Set<String> = []
    @State private var showUnchanged = false
    @State private var initialized = false

    private var changedIDs: Set<String> {
        Set(current.differingFields(from: incoming).map(\.id))
    }

    private var effectiveSelection: Set<String> {
        // Belt and braces: an unchanged row can't be checked, so a stale
        // selection can never write a value that isn't on screen as "New".
        selected.intersection(changedIDs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if changedIDs.isEmpty && !showUnchanged {
                ContentUnavailableView(
                    "Parameters are identical",
                    systemImage: "equal.circle",
                    description: Text("""
                        Every manufacturing constant in the copied design already \
                        matches this one. Nothing to apply.
                        """))
                    .frame(maxHeight: .infinity)
            } else {
                table
            }
            Divider()
            footer
        }
        .frame(minWidth: 540, idealWidth: 620, minHeight: 420, idealHeight: 620)
        .onAppear {
            guard !initialized else { return }
            initialized = true
            // Default true for every parameter that actually differs — the
            // common case is "take all of it", and unchanged rows would just
            // be noise in the selection.
            selected = changedIDs
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Paste Manufacturing Parameters").font(.title3).bold()
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private var subtitle: String {
        let source = sourceName.map { "“\($0)”" } ?? "another design"
        let changed = changedIDs.count
        let total = ManufacturingParameterField.all.count
        guard changed > 0 else {
            return "Copied from \(source). All \(total) parameters already match."
        }
        return "Copied from \(source). "
            + "\(changed) of \(total) parameter\(total == 1 ? "" : "s") "
            + "differ\(changed == 1 ? "s" : "") — checked rows will be applied."
    }

    private var table: some View {
        ScrollView {
            Grid(alignment: .leadingFirstTextBaseline,
                 horizontalSpacing: 10, verticalSpacing: 5) {
                GridRow {
                    Text("")
                    Text("Parameter")
                    Text("Current")
                    Text("New")
                }
                .font(.caption2.bold())
                .foregroundStyle(.secondary)

                ForEach(visibleGroups, id: \.group) { section in
                    GridRow {
                        Text(section.group)
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                            .gridCellColumns(4)
                    }
                    ForEach(section.fields) { field in
                        row(field)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func row(_ field: ManufacturingParameterField) -> some View {
        let changed = changedIDs.contains(field.id)
        GridRow {
            if changed {
                Button {
                    if selected.contains(field.id) {
                        selected.remove(field.id)
                    } else {
                        selected.insert(field.id)
                    }
                } label: {
                    Image(systemName: selected.contains(field.id)
                          ? "checkmark.square.fill" : "square")
                        .foregroundStyle(selected.contains(field.id)
                                         ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("Apply this parameter")
            } else {
                // Unchanged rows have nothing to apply, so they get a dash
                // instead of a checkbox that would be a no-op either way.
                Text("–").foregroundStyle(.tertiary)
            }

            Text(field.label)
                .font(.caption)
                .foregroundStyle(changed ? .primary : .secondary)
            Text(field.read(current).display)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(field.read(incoming).display)
                .font(.caption.monospacedDigit())
                .fontWeight(changed ? .bold : .regular)
                .foregroundStyle(changed ? Color.accentColor : Color.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle("Show unchanged", isOn: $showUnchanged)
                .font(.caption)
                .toggleStyle(.switch)
                .controlSize(.mini)
            if changedIDs.count > 1 {
                Button(effectiveSelection.count == changedIDs.count ? "None" : "All") {
                    selected = effectiveSelection.count == changedIDs.count ? [] : changedIDs
                }
                .font(.caption)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Apply") {
                onApply(effectiveSelection)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(effectiveSelection.isEmpty)
        }
        .padding(14)
    }

    private var visibleGroups: [(group: String, fields: [ManufacturingParameterField])] {
        ManufacturingParameterField.grouped.compactMap { section in
            let fields = showUnchanged
                ? section.fields
                : section.fields.filter { changedIDs.contains($0.id) }
            return fields.isEmpty ? nil : (section.group, fields)
        }
    }
}
