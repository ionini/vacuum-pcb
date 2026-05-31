import Combine
import SwiftUI
import UniformTypeIdentifiers

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
    /// Threaded down so this view can plant the Inspector toolbar toggle as
    /// the rightmost toolbar item.
    @Binding var showInspector: Bool
    /// Passed in from DocumentView so the Export menu can sit immediately
    /// before the Inspector toggle on the trailing edge.
    let exportMenu: ExportMenuButton

    @State private var viewMode: ViewMode = .schematic
    /// Layer-visibility filter for the physical heatmap. Mirrors the editor's
    /// per-layer pills so the user can isolate T0 / B0 / etc. while tracing
    /// pressure flow. Schematic mode ignores this.
    @State private var visible: LayerVisibility = .both

    enum ViewMode: Hashable { case schematic, physical }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: document.circuit) { _, new in
                // Rebuild the network whenever the document changes so newly
                // added components / nets show up in the heatmap immediately.
                state.rebuild(from: new)
            }
            .toolbar { simulateToolbar }
    }

    @ViewBuilder private var content: some View {
        Group {
            switch viewMode {
            case .schematic:
                SimulateSchematicCanvas(document: document.circuit, state: state)
            case .physical:
                SimulatePhysicalCanvas(document: document.circuit, state: state,
                                       visible: visible)
            }
        }
        .background { SimulationClock(state: state) }
    }

    /// All view-mode / transport / speed controls go in the window toolbar
    /// rather than a hand-rolled strip — the system handles Liquid Glass
    /// styling, overflow into a chevron menu when the window narrows, and
    /// keyboard focus for free. Transport controls sit in `.navigation`
    /// (leading) the way Xcode places its run/stop buttons.
    @ToolbarContentBuilder private var simulateToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                state.isPlaying.toggle()
            } label: {
                Label(state.isPlaying ? "Pause" : "Play",
                      systemImage: state.isPlaying ? "pause.fill" : "play.fill")
            }
            .help(state.isPlaying ? "Pause the simulator" : "Resume the simulator")
        }

        ToolbarItem(placement: .navigation) {
            Button {
                state.reset()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .help("Snap every net back to atmosphere")
        }

        ToolbarItem(placement: .navigation) {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .foregroundStyle(.secondary)
                Slider(value: $state.params.timeScale, in: 0.1...20.0)
                    .frame(width: 100)
                Text(String(format: "×%.1f", state.params.timeScale))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)
            }
        }

        // Both editing modes have a physical heatmap to show — the canvas
        // renders the subpart-flattened doc, so an assembly's mated boards
        // lay out in one world-space frame just like a single board's
        // routes and components do.
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $viewMode) {
                Text("Schematic").tag(ViewMode.schematic)
                Text("Physical").tag(ViewMode.physical)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        // Layer visibility is only relevant on the physical heatmap.
        if viewMode == .physical {
            ToolbarItem(placement: .automatic) {
                Picker("Plates", selection: $visible) {
                    Text("All").tag(LayerVisibility.both)
                    Text("Top").tag(LayerVisibility.topOnly)
                    Text("Bottom").tag(LayerVisibility.bottomOnly)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
            }
            ToolbarItem(placement: .automatic) {
                LayerVisibilityPills(layers: allLayers, visible: $visible)
            }
        }

        // Export and Inspector go on the trailing edge, in that order, so
        // Inspector lands rightmost with Export immediately to its left.
        ToolbarItem(placement: .primaryAction) { exportMenu }
        ToolbarItem(placement: .primaryAction) {
            InspectorToggleButton(showInspector: $showInspector)
        }
    }

    /// All layers currently configured on the board, in T0…Tn, B0…Bm order.
    private var allLayers: [Layer] {
        document.circuit.physical.layers(in: .top) +
        document.circuit.physical.layers(in: .bottom)
    }

}

/// Invisible ~60 Hz clock that advances the integrator.
///
/// Driven by a plain `Timer` publisher via `.onReceive` rather than a
/// `TimelineView(.animation)`. `TimelineView` re-evaluates its content (and any
/// `.onChange` on it) on *every* frame, and on this OS that stranded a SwiftUI
/// observation-tracking node per frame — `ObservationRegistrar` instances piled
/// up and the CPU crept to 100% the longer the sim ran (confirmed by a `heap`
/// generation diff: the leak grew at the frame rate while playing and stopped
/// dead when paused). `.onReceive` fires its action without re-evaluating this
/// view's `body`, and the wall-clock delta now lives in `SimulationState.tick()`
/// (`@ObservationIgnored`), so a tick touches no view state at all. `advance`
/// already no-ops when paused, so the always-on timer is harmless; it stops
/// entirely when the Simulate tab leaves the view hierarchy.
private struct SimulationClock: View {
    let state: SimulationState

    private let ticks = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        Color.clear
            .onReceive(ticks) { _ in state.tick() }
    }
}

/// Horizontal row of T0/B1/… pill toggles for layer visibility. Used by
/// both PhysicalView's toolbar (when editing) and SimulateView's toolbar
/// (on the physical heatmap), so muscle memory carries over.
///
/// When `order` is supplied the pills become drag-reorderable: dragging a
/// pill rewrites the bound array, and the canvas reads the same array to
/// decide which layer paints on top (drag a pill to the right end to bring
/// its routes / parts above the rest). The displayed row follows that order.
/// Without `order` the row is static — the Simulate heatmap doesn't care
/// about stacking, so it leaves the binding off.
struct LayerVisibilityPills: View {
    let layers: [Layer]
    @Binding var visible: LayerVisibility
    var order: Binding<[Layer]>?

    @State private var dragging: Layer?

    var body: some View {
        // Outer padding keeps the pills from touching the toolbar item's
        // glass-effect capsule — without it the leading and trailing pill
        // crash into the container edge and look cramped.
        HStack(spacing: 6) {
            ForEach(layers, id: \.self) { layer in
                if let order {
                    pill(layer)
                        .onDrag {
                            dragging = layer
                            return NSItemProvider(object: layer.uiLabel as NSString)
                        }
                        .onDrop(of: [.text], delegate: LayerReorderDrop(
                            item: layer, order: order, dragging: $dragging))
                } else {
                    pill(layer)
                }
            }
        }
        .padding(.horizontal, 6)
    }

    @ViewBuilder
    private func pill(_ layer: Layer) -> some View {
        let on = visible.contains(layer)
        Button {
            toggle(layer)
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

    /// Promote whatever visibility is currently set to an explicit set, with
    /// the tapped layer flipped. Tapping a chip moves into `.explicit` mode
    /// unconditionally so subsequent taps behave predictably.
    private func toggle(_ layer: Layer) {
        var set = Set(layers.filter { visible.contains($0) })
        if set.contains(layer) {
            set.remove(layer)
        } else {
            set.insert(layer)
        }
        visible = .explicit(set)
    }
}

/// Reorder behaviour for `LayerVisibilityPills`. As a dragged pill enters
/// another pill's slot we splice it into that position in the bound order
/// array, so the row reflows live and the canvas restacks in lockstep. The
/// payload is only used to satisfy `.onDrag`; the actual moved item is read
/// from the shared `dragging` state so no async item loading is needed.
private struct LayerReorderDrop: DropDelegate {
    let item: Layer
    @Binding var order: [Layer]
    @Binding var dragging: Layer?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != item,
              let from = order.firstIndex(of: dragging),
              let to = order.firstIndex(of: item)
        else { return }
        withAnimation {
            order.move(fromOffsets: IndexSet(integer: from),
                       toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
