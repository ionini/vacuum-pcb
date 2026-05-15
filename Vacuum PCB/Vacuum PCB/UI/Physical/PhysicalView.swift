import SwiftUI
import UniformTypeIdentifiers

/// Top-level content of the Physical tab: parking lot on the left, canvas in
/// the middle, layer/tool strip across the bottom of the canvas area.
struct PhysicalView: View {
    @Binding var document: VPCBDocument

    @State private var selection: PhysicalSelection = .none
    @State private var routingState: RoutingState = .idle
    @State private var visible: LayerVisibility = .both
    @State private var routingLayer: Layer = .top
    @State private var routingError: String?

    var body: some View {
        HStack(spacing: 0) {
            ParkingLotView(
                document: document.circuit,
                providerForComponent: { id in
                    NSItemProvider(object: id.uuidString as NSString)
                }
            )
            Divider()
            VStack(spacing: 0) {
                PhysicalCanvasView(
                    document: $document,
                    selection: $selection,
                    routingState: $routingState,
                    visible: $visible,
                    routingLayer: $routingLayer,
                    routingError: $routingError
                )
                Divider()
                bottomStrip
            }
        }
    }

    private var bottomStrip: some View {
        HStack(spacing: 12) {
            Picker("Visible layers", selection: $visible) {
                Text("Both").tag(LayerVisibility.both)
                Text("Top").tag(LayerVisibility.topOnly)
                Text("Bottom").tag(LayerVisibility.bottomOnly)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .labelsHidden()

            Divider().frame(height: 18)

            Picker("Routing layer", selection: $routingLayer) {
                Text("Route ▲ top").tag(Layer.top)
                Text("Route ▼ bottom").tag(Layer.bottom)
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
            .labelsHidden()
            .onChange(of: routingLayer) { _, newLayer in
                // If we're mid-route, update the layer of the in-progress polyline
                // so the user sees the change immediately.
                if case let .routing(netId, wps, _, startsAtVia) = routingState {
                    routingState = .routing(netId: netId, waypoints: wps, layer: newLayer,
                                            startsAtVia: startsAtVia)
                }
            }

            Divider().frame(height: 18)

            boardSizeEditor

            Spacer()

            if let routingError {
                Text(routingError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else {
                statusText
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .frame(minHeight: 44)
    }

    /// Compact "Board: W × H mm" widget for the physical-tab bottom strip.
    /// Full manufacturing settings live on the 3D preview sidebar; here we
    /// only surface the board outline since it directly affects the canvas
    /// the user is editing.
    private var boardSizeEditor: some View {
        HStack(spacing: 4) {
            Text("Board").font(.caption).foregroundStyle(.secondary)
            TextField("", value: boardSizeBinding(\.width),
                      format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 48)
            Text("×").font(.caption).foregroundStyle(.secondary)
            TextField("", value: boardSizeBinding(\.height),
                      format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 48)
            Text("mm").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func boardSizeBinding(_ keyPath: WritableKeyPath<Size, Double>) -> Binding<Double> {
        Binding(
            get: { document.circuit.physical.boardOutline.size[keyPath: keyPath] },
            set: { document.circuit.physical.boardOutline.size[keyPath: keyPath] = max(1, $0) }
        )
    }

    private var statusText: Text {
        switch routingState {
        case .idle:
            switch selection {
            case .none:
                return Text("Drag from parking lot to place. Click pin to start routing. R rotate · F flip layer · ⌫ delete.")
            case .placement(let id):
                let label = document.circuit.logic.components.first(where: { $0.id == id })?.label ?? "?"
                return Text("Placement \(label) selected. R rotate · F flip layer · ⌫ delete.")
            case .routeSegment:
                return Text("Route segment selected. ⌫ to delete.")
            }
        case .routing(let netId, let wps, let layer, _):
            let netLabel = document.circuit.logic.nets.first(where: { $0.id == netId })?.label ?? "?"
            return Text("Routing net \(netLabel) on \(layer == .top ? "top" : "bottom") · \(wps.count) waypoints · V to drop a via, click a pin on this net to commit, ESC to cancel.")
        }
    }
}
