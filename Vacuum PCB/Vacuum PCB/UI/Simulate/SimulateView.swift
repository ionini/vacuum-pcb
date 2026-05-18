import SwiftUI

/// Tab content for the interactive pneumatic simulator. Owns the live
/// `SimulationState`, decides whether to render the schematic-style or
/// physical-style heatmap, and runs a fixed-rate clock that advances the
/// integrator in real time.
///
/// All controls (input toggles, output readouts, transport) live in the
/// DocumentView sidebar via `SimulateControlsView` — that mirrors how the 3D
/// Preview tab parks its manufacturing settings there.
struct SimulateView: View {
    @Binding var document: VPCBDocument
    @Bindable var state: SimulationState

    @State private var viewMode: ViewMode = .schematic
    /// Last wall-clock instant we tick'd the integrator. Updated by the
    /// TimelineView's `date` so the elapsed delta is real seconds.
    @State private var lastTick: Date = .now

    enum ViewMode: Hashable { case schematic, physical }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: document.circuit) { _, new in
            // Rebuild the network whenever the document changes so newly
            // added components / nets show up in the heatmap immediately.
            state.rebuild(from: new)
        }
    }

    @ViewBuilder private var content: some View {
        // Timer drives the integrator at ~60 Hz. Even when paused we keep
        // the timeline going so a future un-pause picks up at the right
        // wall-clock instant without one giant catch-up step.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { ctx in
            Group {
                switch viewMode {
                case .schematic:
                    SimulateSchematicCanvas(document: document.circuit, state: state)
                case .physical:
                    SimulatePhysicalCanvas(document: document.circuit, state: state)
                }
            }
            .onChange(of: ctx.date) { _, newDate in
                let elapsed = max(0, newDate.timeIntervalSince(lastTick))
                lastTick = newDate
                if elapsed > 0 {
                    state.advance(wallSeconds: elapsed)
                }
            }
            .onAppear {
                lastTick = ctx.date
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Picker("View", selection: $viewMode) {
                Text("Schematic").tag(ViewMode.schematic)
                Text("Physical").tag(ViewMode.physical)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .labelsHidden()

            Divider().frame(height: 18)

            Button {
                state.isPlaying.toggle()
            } label: {
                Label(state.isPlaying ? "Pause" : "Play",
                      systemImage: state.isPlaying ? "pause.fill" : "play.fill")
            }
            .controlSize(.small)
            .help(state.isPlaying ? "Pause the simulator" : "Resume the simulator")

            Button {
                state.reset()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .controlSize(.small)
            .help("Snap every net back to atmosphere")

            Divider().frame(height: 18)

            HStack(spacing: 6) {
                Text("Speed").font(.caption).foregroundStyle(.secondary)
                Slider(value: $state.params.timeScale, in: 0.1...5.0)
                    .controlSize(.small)
                    .frame(width: 120)
                Text(String(format: "×%.1f", state.params.timeScale))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .leading)
            }

            Spacer()

            Text(legendText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private var legendText: String {
        // Vacuum is the "active" signal on this device; calling it out keeps
        // newcomers from defaulting to digital-logic intuition ("1 = on").
        "Pressure: 0 vacuum (active) · 1 atmosphere · transistors open when gate sees vacuum"
    }
}
