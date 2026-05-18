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
    /// Layer-visibility filter for the physical heatmap. Mirrors the editor's
    /// per-layer pills so the user can isolate T0 / B0 / etc. while tracing
    /// pressure flow. Schematic mode ignores this.
    @State private var visible: LayerVisibility = .both
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
        // Timer drives the integrator at ~60 Hz. We pause the schedule when
        // the user pauses playback — otherwise every paused tab still
        // burned its tick on a no-op `advance` call and triggered a layout
        // pass for the surrounding views.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !state.isPlaying)) { ctx in
            Group {
                switch viewMode {
                case .schematic:
                    SimulateSchematicCanvas(document: document.circuit, state: state)
                case .physical:
                    SimulatePhysicalCanvas(document: document.circuit, state: state,
                                           visible: visible)
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

            if viewMode == .physical {
                Divider().frame(height: 18)
                layerVisibilityControls
            }

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

    /// Plate-level segmented picker plus per-layer multi-select pills. Same
    /// affordance as the physical editor's bottom strip so the user's muscle
    /// memory carries over: tap T0/B1 to isolate a single channel layer, tap
    /// "All" to bring everything back.
    @ViewBuilder private var layerVisibilityControls: some View {
        Picker("Visible plates", selection: $visible) {
            Text("All").tag(LayerVisibility.both)
            Text("Top").tag(LayerVisibility.topOnly)
            Text("Bottom").tag(LayerVisibility.bottomOnly)
        }
        .pickerStyle(.segmented)
        .frame(width: 180)
        .labelsHidden()

        HStack(spacing: 4) {
            ForEach(allLayers, id: \.self) { layer in
                let on = visible.contains(layer)
                Button {
                    toggleLayer(layer)
                } label: {
                    Text(layer.uiLabel)
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(on ? LayerPalette.color(for: layer).opacity(0.85)
                                       : Color.secondary.opacity(0.12))
                        .foregroundStyle(on ? .white : .secondary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// All layers currently configured on the board, in T0…Tn, B0…Bm order.
    private var allLayers: [Layer] {
        document.circuit.physical.layers(in: .top) +
        document.circuit.physical.layers(in: .bottom)
    }

    /// Promote whatever `visible` currently is to an explicit set, with the
    /// tapped layer flipped. Mirrors `PhysicalView.toggleLayer` so the two
    /// strips behave identically.
    private func toggleLayer(_ layer: Layer) {
        var set = Set(allLayers.filter { visible.contains($0) })
        if set.contains(layer) {
            set.remove(layer)
        } else {
            set.insert(layer)
        }
        visible = .explicit(set)
    }

    private var legendText: String {
        // Vacuum is the "active" signal on this device; calling it out keeps
        // newcomers from defaulting to digital-logic intuition ("1 = on").
        "Pressure: 0 vacuum (active) · 1 atmosphere · transistors open when gate sees vacuum"
    }
}
