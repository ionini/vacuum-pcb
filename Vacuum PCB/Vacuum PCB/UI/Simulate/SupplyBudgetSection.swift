import SwiftUI

/// "Supply" block for the Simulate sidebar: what the pump is delivering right
/// now and which paths are consuming it, ranked worst-first. This is the
/// panel that catches pull-ups fighting an open vent path — the NMOS-style
/// static draw that sags the rail — without having to spot it on the canvas.
///
/// Tapping a component row highlights that body in both Simulate canvases
/// (ring), tap again to clear. Aggregate rows (leak) have nothing to point at.
///
/// One leaf view on purpose (see the note in `SimulateControlsView`): it reads
/// `state.flows`, which republishes at ~20 Hz while playing, so everything
/// here re-renders on that cadence — cheap Texts and bars — while the parent
/// sidebar body (with its expensive segmented Pickers) stays untouched.
struct SupplyBudgetSection: View {
    let state: SimulationState

    var body: some View {
        let report = state.flows
        if report.railPressure != nil || !report.externalDrives.isEmpty {
            // Collapsed by default (and remembered): the ranked consumer list
            // grows with the board and was crowding out the tuning sliders.
            // While collapsed the row builders below aren't evaluated at all.
            CollapsibleSection("Supply", storageKey: "inspectorSupplyExpanded") {
                if let railPressure = report.railPressure {
                    pumpRow(report)
                    railRow(railPressure)
                }
                let consumerMax = report.consumers.map { max(0, $0.q) }.max() ?? 0
                ForEach(report.consumers) { consumer in
                    consumerRow(consumer, relativeTo: consumerMax)
                }
                if !report.externalDrives.isEmpty {
                    Text("External drives").font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 2)
                    ForEach(report.externalDrives) { drive in
                        driveRow(drive)
                    }
                }
            }
        }
    }

    /// Throughput vs the pump's free-flow ceiling. A saturated bar with a
    /// shallow rail is the starvation signature.
    private func pumpRow(_ report: FlowReport) -> some View {
        let utilization = min(1.0, max(0, report.utilization))
        return HStack(spacing: 8) {
            Text("Pump")
                .font(.system(size: 12, weight: .medium).monospaced())
                .frame(width: 56, alignment: .leading)
            Text(Self.flowText(report.pumpThroughput))
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
            ProgressView(value: utilization)
                .progressViewStyle(.linear)
                .tint(utilization > 0.85 ? .orange : .accentColor)
                .animation(nil, value: utilization)
            Text("\(Int((utilization * 100).rounded()))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
        .help("Air the pump is removing right now, against its free-flow " +
              "ceiling (\(Self.flowText(report.pumpFreeFlowMax))). Every row " +
              "below is a path feeding that load.")
    }

    private func railRow(_ railPressure: Double) -> some View {
        HStack(spacing: 8) {
            Text("Rail")
                .font(.system(size: 12, weight: .medium).monospaced())
                .frame(width: 56, alignment: .leading)
            Text(PressureColor.formatted(railPressure))
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
            ProgressView(value: 1 - railPressure)
                .progressViewStyle(.linear)
                .tint(PressureColor.strokeColor(for: railPressure))
                .animation(nil, value: railPressure)
            Text("dh \(String(format: "%.2f", state.params.pumpMaxVacuum))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
                .help("Deadhead — the deepest the pump could reach at zero flow. " +
                      "The gap between rail and deadhead is what the draw below costs.")
        }
    }

    private func consumerRow(_ consumer: FlowReport.Consumer, relativeTo maxQ: Double) -> some View {
        let selected = consumer.componentId != nil
            && consumer.componentId == state.highlightedComponentId
        return HStack(spacing: 8) {
            Image(systemName: Self.icon(for: consumer.kind))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(consumer.label)
                .font(.system(size: 12, weight: .medium).monospaced())
                .frame(width: 56, alignment: .leading)
                .lineLimit(1)
            Text(Self.flowText(consumer.q))
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
            ProgressView(value: maxQ > 0 ? min(1.0, max(0, consumer.q) / maxQ) : 0)
                .progressViewStyle(.linear)
                .tint(.orange)
                .animation(nil, value: consumer.q)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 2)
        .background(selected ? Color.accentColor.opacity(0.15) : .clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture {
            guard let componentId = consumer.componentId else { return }
            state.highlightedComponentId =
                state.highlightedComponentId == componentId ? nil : componentId
        }
        .help("\(consumer.label) — \(consumer.detail). Air drawn into the rail "
              + "through this path\(consumer.componentId == nil ? "" : "; tap to highlight on the canvas").")
    }

    /// An asserted soft (bus) drive: supply work done by the external bench
    /// line, outside the on-board pump's budget.
    private func driveRow(_ drive: FlowReport.ExternalDrive) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.right.circle")
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(drive.label)
                .font(.system(size: 12, weight: .medium).monospaced())
                .frame(width: 56, alignment: .leading)
                .lineLimit(1)
            Text(drive.towardVacuum ? "→ Vac" : "→ Atm")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text(Self.flowText(drive.q))
                .font(.caption.monospacedDigit())
        }
        .help(drive.towardVacuum
              ? "Air this external Vac drive is pulling out of the board."
              : "Air this external Atm drive is pushing into the board (negative = it's absorbing instead).")
    }

    private static func icon(for kind: FlowReport.ConsumerKind) -> String {
        switch kind {
        case .resistor:     return "r.square"
        case .transistor:   return "t.square"
        case .railLeak:     return "aqi.medium"
        case .internalLeak: return "wind"
        }
    }

    /// Fixed-width flow figure. Three decimals resolves the calibrated range
    /// (pump ceiling ≈ 0.054, leak crawl ≈ 0.005) without jitter.
    private static func flowText(_ q: Double) -> String {
        String(format: "%.3f", q)
    }
}
