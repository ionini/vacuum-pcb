import SwiftUI

/// In-app validation battery. Runs the exact same `Validators` checks as
/// `vacuum-cli` (the shared source of truth) off the main actor and shows a
/// green/red gate per check. Heavy (CAD mesh build + exhaustive sweeps), so
/// it's manual — hit Run. Concurrency mirrors `DocumentView.rebuild()`: snapshot
/// the value-type document, compute on a global queue, mutate @State on main,
/// guard against stale runs with a token.
struct ValidateView: View {
    @Binding var document: VPCBDocument

    @State private var reports: [Validators.Report] = ValidateView.idleReports
    @State private var isRunning = false
    @State private var progressText: String?
    @State private var runToken = 0
    @State private var ranOnce = false

    private static let titles = [
        "Connectivity (top-level)",
        "Self-containment",
        "Printability (mesh)",
        "Logic + convergence",
        "Robustness (±20%)",
    ]
    private static var idleReports: [Validators.Report] {
        titles.map { Validators.Report(id: $0, title: $0, status: .pending, detail: ["Not run yet"]) }
    }

    private var overall: Validators.Report.Status {
        if isRunning { return .running }
        if !ranOnce { return .pending }
        if reports.contains(where: { $0.status == .fail }) { return .fail }
        if reports.contains(where: { $0.status == .warn }) { return .warn }
        return .pass
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                ForEach(reports) { reportCard($0) }
                footnote
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            statusIcon(overall, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("Validate").font(.title2).bold()
                Text(headline).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if isRunning, let progressText {
                Text(progressText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Button(isRunning ? "Running…" : (ranOnce ? "Re-run" : "Run validation")) { run() }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning)
        }
    }

    private var headline: String {
        switch overall {
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
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private var footnote: some View {
        Text("Runs against simulation defaults. Connectivity is top-level only — open each subpart file to check its internals. Mesh judges the same watertight stitching the STL export uses.")
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

    // MARK: - Run (GCD off-main, mirrors DocumentView.rebuild)

    private func run() {
        runToken += 1
        let token = runToken
        let snapshot = document.circuit
        let params = SimulationParameters.defaults
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
        return Report(id: titles[4], title: titles[4], status: .fail,
                      detail: m.failures.prefix(10).map { "• \($0)" })
    }

    private typealias Report = Validators.Report
}
