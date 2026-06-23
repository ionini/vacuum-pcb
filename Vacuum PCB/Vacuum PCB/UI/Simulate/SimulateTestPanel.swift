//
//  SimulateTestPanel.swift
//  Vacuum PCB
//
//  The Simulate tab's bottom test drawer: paste a Vacuum Tester DSL script on
//  the left, map its logical pins onto this board's named ports, and watch the
//  per-test / per-step results light green/red on the right as the script drives
//  the live simulation. Mirrors the bench app's Tests view; the runner
//  (SimTestRunner) targets `SimulationState` instead of BLE hardware.
//

import SwiftUI

struct SimulateTestPanel: View {
    @Bindable var model: SimTestModel
    @Bindable var state: SimulationState
    /// The DSL script, stored on the document so it persists with the design.
    @Binding var source: String

    var body: some View {
        let parsed = TestParser.parse(source)
        HStack(alignment: .top, spacing: 0) {
            editorColumn(parsed)
                .frame(minWidth: 170, idealWidth: 360, maxWidth: 460)
                .padding(12)
            Divider()
            resultsColumn
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
    }

    // MARK: - Left: editor, mapping, transport

    @ViewBuilder
    private func editorColumn(_ parsed: ParsedScript) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Tests").font(.headline)
                Text("1 = vacuum")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("A script's 1 / high means vacuum: `set 1` pulls vacuum and `assert 1` passes when the probe is in vacuum (pressure < 0.5).")
                Spacer()
                runButton(parsed)
            }

            TextEditor(text: $source)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(maxHeight: .infinity)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.25)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #endif

            if !parsed.issues.isEmpty {
                issues(parsed.issues)
            } else if state.network.inputs.isEmpty && state.network.probes.isEmpty {
                Label("This board has no input ports or probes to drive — add a port to test it.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                mapping(parsed)
            }
        }
    }

    @ViewBuilder
    private func runButton(_ parsed: ParsedScript) -> some View {
        if model.runner.isRunning {
            Button(role: .destructive) { model.runner.stop() } label: {
                Label("Stop", systemImage: "stop.fill")
            }
        } else {
            Button {
                model.runner.run(parsed.tests, state: state, model: model)
            } label: {
                Label("Run", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!parsed.isValid || parsed.tests.isEmpty
                      || (state.network.inputs.isEmpty && state.network.probes.isEmpty))
        }
    }

    private func issues(_ list: [ParseIssue]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(list) { issue in
                Label("Line \(issue.line): \(issue.message)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Mapping rows for only the pins the script actually references, so the
    /// strip stays short. Each picker defaults to the positional auto-map and
    /// records an override when changed.
    @ViewBuilder
    private func mapping(_ parsed: ParsedScript) -> some View {
        let outs = parsed.referencedOutputs
        let chs = parsed.referencedChannels
        if !outs.isEmpty || !chs.isEmpty {
            DisclosureGroup("Pin mapping") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(outs, id: \.self) { out in
                        mapRow(pin: "out\(out)", drives: true,
                               selection: outputBinding(out),
                               options: state.network.inputs.map { ($0.id, $0.label) })
                    }
                    ForEach(chs, id: \.self) { ch in
                        mapRow(pin: "ch\(ch)", drives: false,
                               selection: channelBinding(ch),
                               options: state.network.probes.map { ($0.id, $0.label) })
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption)
        }
    }

    private func mapRow(pin: String, drives: Bool, selection: Binding<UUID?>,
                        options: [(UUID, String)]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: drives ? "arrow.right.circle" : "dot.circle")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            Text(pin)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 52, alignment: .leading)
            Picker("", selection: selection) {
                Text("—").tag(UUID?.none)
                ForEach(options, id: \.0) { id, label in
                    Text(label).tag(UUID?.some(id))
                }
            }
            .labelsHidden()
        }
    }

    private func outputBinding(_ out: Int) -> Binding<UUID?> {
        Binding(
            get: { model.input(forOutput: out, network: state.network)?.id },
            set: { if let v = $0 { model.outOverrides[out] = v } }
        )
    }

    private func channelBinding(_ ch: Int) -> Binding<UUID?> {
        Binding(
            get: { model.probe(forChannel: ch, network: state.network)?.id },
            set: { if let v = $0 { model.chOverrides[ch] = v } }
        )
    }

    // MARK: - Right: results

    @ViewBuilder
    private var resultsColumn: some View {
        if model.runner.results.isEmpty {
            VStack {
                Spacer()
                Label("Run a script to see step results.", systemImage: "checklist")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Results").font(.headline)
                        Spacer()
                        Text("\(model.runner.passedCount) passed · \(model.runner.failedCount) failed")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.runner.results) { test in
                        resultCard(test)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func resultCard(_ test: SimTestRunner.TestResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusIcon(status: test.status)
                Text(test.name).font(.subheadline.weight(.semibold))
            }
            ForEach(test.steps) { step in
                HStack(alignment: .top, spacing: 8) {
                    StatusIcon(status: step.status)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.label).font(.system(.caption, design: .monospaced))
                        if let detail = step.detail {
                            Text(detail).font(.caption2).foregroundStyle(.red)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 8)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.2)))
    }
}

/// Per-test / per-step status glyph: hollow circle (pending), spinner (running),
/// green check (passed), red x (failed), grey minus (skipped). Ported verbatim
/// from the bench Tester so the two apps read identically.
private struct StatusIcon: View {
    let status: SimTestRunner.Status

    var body: some View {
        switch status {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .passed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}
