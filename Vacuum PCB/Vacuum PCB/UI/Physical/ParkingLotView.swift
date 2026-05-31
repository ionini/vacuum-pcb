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
    let onPlaceAll: () -> Void
    /// Simulated-annealing die compaction over the already-placed-and-routed
    /// board: shrinks the board outline, re-routing as it goes (multi-layer
    /// aware) and never increasing the DRC issue count, then shrink-fits the
    /// outline.
    let onMinimize: () -> Void
    /// True while a minimize run is in flight — drives the button's spinner
    /// and disabled state.
    let isMinimizing: Bool
    /// Diagnostics from the last minimize run, shown as a compact readout
    /// under the button. Nil before the first run.
    let minimizeStats: Minimizer.Stats?

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

            Divider().padding(.vertical, 4)
            Text("Optimize").font(.caption.bold()).foregroundStyle(.secondary)
            Button(action: onMinimize) {
                HStack(spacing: 5) {
                    if isMinimizing { ProgressView().controlSize(.mini) }
                    Text(isMinimizing ? "Minimizing…" : "Minimize")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(isMinimizing || document.physical.placements.count < 2)
            .help("Shrink the die: anneal placements while re-routing, then fit the outline")

            if let s = minimizeStats, !isMinimizing {
                minimizeReadout(s)
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        // Lives inside the document inspector now; no fixed width and no
        // opaque background — the inspector column provides both.
    }

    /// Compact post-run summary: how many search trials ran, what happened to
    /// the die, and the DRC count before/after. Shows the user the search did
    /// real work even when it declines to change an already-tight board.
    @ViewBuilder
    private func minimizeReadout(_ s: Minimizer.Stats) -> some View {
        let beforeArea = s.outlineBefore.size.width * s.outlineBefore.size.height
        let afterArea = s.outlineAfter.size.width * s.outlineAfter.size.height
        let areaPct = beforeArea > 0 ? (1 - afterArea / beforeArea) * 100 : 0
        let wirePct = s.wirelengthBefore > 0 ? (1 - s.wirelengthAfter / s.wirelengthBefore) * 100 : 0
        VStack(alignment: .leading, spacing: 2) {
            Text("\(s.iterations.formatted()) trials · \(String(format: "%.1fs", s.elapsed))")
                .foregroundStyle(.secondary)
            if s.adopted, afterArea < beforeArea - 0.5 {
                Text("\(dims(s.outlineBefore)) → \(dims(s.outlineAfter)) mm  (−\(String(format: "%.0f", areaPct))% area)")
                    .foregroundStyle(.green)
            } else if s.adopted {
                Text("tidier layout (wiring −\(String(format: "%.0f", max(0, wirePct)))%)")
                    .foregroundStyle(.green)
            } else {
                Text("already compact — no smaller fit found")
                    .foregroundStyle(.secondary)
            }
            Text("DRC \(s.baselineIssues) → \(s.finalIssues)")
                .foregroundStyle(s.finalIssues > s.baselineIssues ? .orange : .secondary)
        }
        .font(.caption2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    private func dims(_ r: Rect) -> String {
        "\(Int(r.size.width.rounded()))×\(Int(r.size.height.rounded()))"
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
        case .subpart:
            RoundedRectangle(cornerRadius: 3).fill(Color.teal.opacity(0.35))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.teal, lineWidth: 1))
        case .screw:
            Circle().fill(Color.gray.opacity(0.45))
                .overlay(Circle().stroke(.gray, lineWidth: 1))
        case .led:
            Circle().fill(Color.yellow.opacity(0.45))
                .overlay(Circle().stroke(.yellow, lineWidth: 1))
        case .connector:
            RoundedRectangle(cornerRadius: 3).fill(Color.indigo.opacity(0.35))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.indigo, lineWidth: 1))
        }
    }
}
