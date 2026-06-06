import SwiftUI
import Observation

/// Holds the Validate panel's results so they survive tab switches — owned by
/// `DocumentView` (not by the view), and only reset when the design changes
/// (`invalidate()`). Runs the shared `Validators` battery off the main actor,
/// mirroring `DocumentView.rebuild()`'s GCD + token pattern.
@Observable
@MainActor
final class ValidationModel {
    var reports: [Validators.Report] = ValidationModel.idleReports
    var isRunning = false
    var progressText: String?
    var ranOnce = false
    @ObservationIgnored private var runToken = 0

    static let titles = [
        "Connectivity (top-level)",
        "Self-containment",
        "Printability (mesh)",
        "Logic + convergence",
        "Robustness (±20%)",
    ]
    static var idleReports: [Validators.Report] {
        titles.map { Validators.Report(id: $0, title: $0, status: .pending, detail: ["Not run yet"]) }
    }

    var overall: Validators.Report.Status {
        if isRunning { return .running }
        if !ranOnce { return .pending }
        if reports.contains(where: { $0.status == .fail }) { return .fail }
        if reports.contains(where: { $0.status == .warn }) { return .warn }
        return .pass
    }

    /// Drop stale results — called when the design is edited. Also cancels any
    /// in-flight run by advancing the token so its posts are ignored.
    func invalidate() {
        guard ranOnce || isRunning else { return }
        runToken += 1
        isRunning = false
        progressText = nil
        ranOnce = false
        reports = Self.idleReports
    }

    func run(snapshot: CircuitDocument, params: SimulationParameters) {
        runToken += 1
        let token = runToken
        isRunning = true
        ranOnce = true
        progressText = "Starting…"
        reports = Self.titles.map { Validators.Report(id: $0, title: $0, status: .running, detail: ["…"]) }

        DispatchQueue.global(qos: .userInitiated).async {
            func post(_ idx: Int, _ r: Validators.Report) {
                DispatchQueue.main.async {
                    guard token == self.runToken else { return }
                    self.reports[idx] = r
                }
            }
            func setProgress(_ s: String) {
                DispatchQueue.main.async { if token == self.runToken { self.progressText = s } }
            }

            setProgress("Connectivity…")
            post(0, Self.connectivityReport(Validators.connectivity(snapshot)))

            setProgress("Self-containment…")
            post(1, Self.stalenessReport(Validators.staleness(snapshot, libDir: nil)))

            setProgress("Building plates…")
            post(2, Self.meshReport(Validators.mesh(snapshot)))

            setProgress("Exhaustive sweep…")
            let net = Validators.buildNetwork(snapshot)
            post(3, Self.sweepReport(Validators.sweep(
                network: net, params: params, maxSteps: 20000, epsilon: 1e-5, maxCombos: 4096)))

            let marg = Validators.margins(
                network: net, base: params, tol: 0.2, maxSteps: 20000, epsilon: 1e-5, maxCombos: 4096
            ) { c, total, _, _, _ in setProgress("Margins corner \(c)/\(total)…") }
            post(4, Self.marginsReport(marg))

            DispatchQueue.main.async {
                guard token == self.runToken else { return }
                self.isRunning = false
                self.progressText = nil
            }
        }
    }

    // MARK: - Result → Report

    private typealias Report = Validators.Report

    private static func connectivityReport(_ c: Validators.ConnResult) -> Report {
        if c.pass {
            return Report(id: titles[0], title: titles[0], status: .pass,
                          detail: ["All nets routed, no DRC issues (top level)."])
        }
        var d = ["DRC issues: \(c.drcIssues.count)", "Unrouted nets: \(c.unrouted)"]
        d += c.drcIssues.prefix(6).map { "• \($0.summary)" }
        return Report(id: titles[0], title: titles[0], status: .fail, detail: d)
    }

    private static func stalenessReport(_ s: Validators.StalenessResult) -> Report {
        if s.pass {
            var d = ["Self-contained — every subpart pinned to an embedded snapshot."]
            if !s.info.isEmpty { d.append("\(s.info.count) snapshot(s) predate the current schema (benign).") }
            return Report(id: titles[1], title: titles[1], status: .pass, detail: d)
        }
        return Report(id: titles[1], title: titles[1], status: .fail,
                      detail: (s.hardProblems + s.stale).map { "• \($0)" })
    }

    private static func meshReport(_ m: Validators.MeshResult) -> Report {
        let d = m.bodies.map { b -> String in
            if b.empty { return "\(b.name): empty\(b.required ? "  ✗ required" : "  (disabled)")" }
            return String(format: "%@ %@: watertight %@, %.0f mm³, %d polys",
                          b.pass ? "✓" : "✗", b.name, b.watertight ? "yes" : "NO",
                          b.signedVolume, b.polygons)
        }
        return Report(id: titles[2], title: titles[2], status: m.pass ? .pass : .fail, detail: d)
    }

    private static func sweepReport(_ sw: Validators.SweepResult) -> Report {
        if let n = sw.tooManyCombos {
            return Report(id: titles[3], title: titles[3], status: .warn,
                          detail: ["Skipped: \(n) input combinations exceed the cap."])
        }
        let conv = sw.rows.filter(\.converged).count
        var d = ["\(conv)/\(sw.rows.count) input combinations converge (no oscillation)."]
        if conv != sw.rows.count {
            d.append("Non-converging (oscillating / metastable):")
            d += sw.rows.filter { !$0.converged }.prefix(8).map { "• [\($0.bits.map(String.init).joined())]" }
        }
        return Report(id: titles[3], title: titles[3], status: sw.allConverged ? .pass : .fail, detail: d)
    }

    private static func marginsReport(_ m: Validators.MarginResult) -> Report {
        if m.pass {
            return Report(id: titles[4], title: titles[4], status: .pass,
                          detail: ["Logic stable + converges across all \(m.corners) ±\(Int(m.tol * 100))% corners (\(m.keys.joined(separator: ", ")))."])
        }
        let detail = m.failures.prefix(10).map { "• [\($0.label)]: \($0.detail)" }
        // Each failing corner becomes an "Open in Simulate" action carrying the
        // exact parameters that produced it.
        let actions = m.failures.prefix(8).map {
            Validators.ReportAction(label: "Open in Simulate: \($0.label)", params: $0.params)
        }
        return Report(id: titles[4], title: titles[4], status: .fail, detail: Array(detail), actions: Array(actions))
    }
}

/// In-app validation battery. Renders `ValidationModel`'s per-check gates;
/// failing margin corners get an "Open in Simulate" button that jumps to the
/// Simulate tab with that corner's parameters applied.
struct ValidateView: View {
    let model: ValidationModel
    @Binding var document: VPCBDocument
    let onOpenInSimulate: (SimulationParameters) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                ForEach(model.reports) { reportCard($0) }
                footnote
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            statusIcon(model.overall, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("Validate").font(.title2).bold()
                Text(headline).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if model.isRunning, let progressText = model.progressText {
                Text(progressText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Button(model.isRunning ? "Running…" : (model.ranOnce ? "Re-run" : "Run validation")) {
                model.run(snapshot: document.circuit, params: .defaults)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isRunning)
        }
    }

    private var headline: String {
        switch model.overall {
        case .pending: return "Connectivity, self-containment, a printable watertight mesh, exhaustive logic + convergence, and ±20% parameter margins — one gate each."
        case .running: return "Running the battery off the main thread…"
        case .pass:    return "All gates green."
        case .warn:    return "Passed, with warnings — see below."
        case .fail:    return "One or more gates failed — see below."
        }
    }

    @ViewBuilder private func reportCard(_ r: Validators.Report) -> some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon(r.status, size: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(r.title).font(.headline)
                ForEach(Array(r.detail.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !r.actions.isEmpty {
                    FlowButtons(actions: r.actions, onTap: onOpenInSimulate)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private var footnote: some View {
        Text("Runs against simulation defaults. Connectivity is top-level only — open each subpart file to check its internals. Mesh judges the same watertight stitching the STL export uses. Results persist across tabs and reset only when you edit the design.")
            .font(.caption2).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func statusIcon(_ s: Validators.Report.Status, size: CGFloat) -> some View {
        switch s {
        case .pass:    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: size))
        case .fail:    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).font(.system(size: size))
        case .warn:    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: size))
        case .running: ProgressView().controlSize(.small)
        case .pending: Image(systemName: "circle.dashed").foregroundStyle(.secondary).font(.system(size: size))
        }
    }
}

/// Wrapping row of "Open in Simulate" buttons, one per failing corner.
private struct FlowButtons: View {
    let actions: [Validators.ReportAction]
    let onTap: (SimulationParameters) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(actions) { action in
                Button {
                    onTap(action.params)
                } label: {
                    Label(action.label, systemImage: "waveform.path.badge.plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}
