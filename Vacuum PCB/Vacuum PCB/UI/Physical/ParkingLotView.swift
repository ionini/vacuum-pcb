import SwiftUI
import UniformTypeIdentifiers

/// Sidebar listing components from the logic graph that don't yet have a
/// physical placement. Drag a row onto the canvas to place that component.
struct ParkingLotView: View {
    let document: CircuitDocument
    /// Called when the user begins a drag for a given component.
    /// The receiver uses NSItemProvider to ship the component id.
    let providerForComponent: (UUID) -> NSItemProvider
    /// Drops every unplaced component onto the board in a default grid.
    /// Useful for big imported schematics where one-by-one drags would be
    /// tedious — the user can then rearrange + start routing.
    let onPlaceAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Parking lot")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.top, 4)

            if unplaced.isEmpty {
                Text("All placed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Button("Place all", action: onPlaceAll)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(unplaced) { c in
                            row(c)
                        }
                    }
                }
            }
            Spacer()
        }
        .frame(width: 160)
        .padding(.horizontal, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var unplaced: [Component] {
        let placed = Set(document.physical.placements.map(\.componentId))
        return document.logic.components.filter { !placed.contains($0.id) }
    }

    private func row(_ c: Component) -> some View {
        HStack(spacing: 6) {
            kindGlyph(c)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(c.label).font(.system(size: 12, weight: .medium))
                Text(c.kind.displayName).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.primary.opacity(0.18))
        )
        .onDrag { providerForComponent(c.id) }
    }

    @ViewBuilder private func kindGlyph(_ c: Component) -> some View {
        switch c.kind {
        case .transistor:
            Circle().fill(Color.blue.opacity(0.35)).overlay(Circle().stroke(.blue, lineWidth: 1))
        case .resistor:
            RoundedRectangle(cornerRadius: 3).fill(Color.orange.opacity(0.35))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.orange, lineWidth: 1))
                .frame(height: 10)
        case .vacuumSource:
            RoundedRectangle(cornerRadius: 3).fill(Color.red.opacity(0.35))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.red, lineWidth: 1))
        case .atmVent:
            RoundedRectangle(cornerRadius: 3).fill(Color.green.opacity(0.35))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.green, lineWidth: 1))
        case .port:
            RoundedRectangle(cornerRadius: 3).fill(Color.purple.opacity(0.35))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.purple, lineWidth: 1))
        }
    }
}
