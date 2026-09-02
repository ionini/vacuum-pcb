import SwiftUI

/// Inspector list of physical volumes for the 3D preview. Selecting a row
/// glows that cavity in the scene; the selected volume's holes are listed
/// underneath so they can be cross-referenced while probing the printed plate.
///
/// A "volume" is one sealed air cavity in a single plate (see
/// `physicalVolumes`). This is the unit you bench-test before assembly: plug
/// every hole but one, pull vacuum on the last, and a perfect vacuum confirms
/// the cavity is fully connected and leak-free.
struct VolumeListView: View {
    let volumes: [Volume]
    /// Volume ids currently glowing in the scene (one when picked here, two
    /// when shown from a collision). Rows in the set are tinted.
    let highlighted: Set<String>
    /// Toggle a volume's highlight (the parent decides single vs. clearing).
    let onSelect: (String) -> Void

    var body: some View {
        let top = volumes.filter { $0.plate == .top }
        let bottom = volumes.filter { $0.plate == .bottom }
        CollapsibleSection(
            volumes.isEmpty ? "Physical volumes" : "Physical volumes (\(volumes.count))",
            storageKey: "inspectorVolumesExpanded",
            titleFont: .headline
        ) {
            Text("Each is one sealed air cavity in a single plate. Select one here — or click it in the 3D view (right-click / long-press to glow only as far as its resistors) — to glow it; on the printed plate, plug every hole but one and pull a vacuum on the last — a perfect vacuum confirms that cavity.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if volumes.isEmpty {
                Text("Build the preview to compute volumes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                plateGroup("Top plate", top)
                plateGroup("Bottom plate", bottom)
            }
        }
    }

    @ViewBuilder
    private func plateGroup(_ title: String, _ vs: [Volume]) -> some View {
        if !vs.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(title) · \(vs.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                ForEach(vs) { row($0) }
            }
        }
    }

    @ViewBuilder
    private func row(_ v: Volume) -> some View {
        let isSelected = highlighted.contains(v.id)
        VStack(alignment: .leading, spacing: 4) {
            Button {
                onSelect(v.id)
            } label: {
                HStack(spacing: 8) {
                    Text(v.id)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .frame(minWidth: 34, alignment: .leading)
                    Text(v.netLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text("\(v.holes.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(isSelected ? Color.accentColor.opacity(0.20) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))

            if isSelected {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(v.holes, id: \.self) { hole in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: hole.isBridge ? "arrow.up.arrow.down.circle.fill" : "smallcircle.filled.circle")
                                .font(.system(size: 8))
                                .foregroundStyle(hole.isBridge ? Color.orange : Color.secondary)
                                .padding(.top, 3)
                            Text("\(hole.ref) · \(hole.feature) · \(hole.layer.uiLabel) · (\(fmt(hole.pos.x)), \(fmt(hole.pos.y)))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 12)
                .padding(.bottom, 4)
            }
        }
    }

    private func fmt(_ v: Double) -> String { String(format: "%.1f", v) }
}
