import SwiftUI

/// Shared pan / zoom shell for the Simulate tab canvases. Wraps unscaled
/// content in `scaleEffect` + `offset`, wires the same gesture surface the
/// editing canvases expose (magnify, ⌘+/⌘−/⌘0, trackpad scroll, ⌘+scroll),
/// and floats a `ZoomToolbar` in the top-right corner.
///
/// The host view supplies one `Fit` closure that, given the viewport size,
/// returns the zoom factor and pan offset that frame the content. We call it
/// on first appear, on every viewport resize before the user has interacted,
/// and whenever the user presses ⌘0.
struct SimulatePanZoom<Content: View>: View {
    typealias Fit = (CGSize) -> (zoom: Double, pan: CGSize)

    let fit: Fit
    @ViewBuilder var content: () -> Content

    @State private var zoom: Double = 1.0
    @State private var pan: CGSize = .zero
    @State private var userAdjusted: Bool = false
    @State private var magnifyBaseline: (zoom: Double, pan: CGSize)?
    @State private var windowCursor: CGPoint = .zero
    @State private var bgDragMode: BgDragMode = .none
    @State private var panBaseline: CGSize = .zero

    private enum BgDragMode { case none, pan }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.canvasBackground
                    .ignoresSafeArea(edges: [])

                content()
                    .scaleEffect(zoom, anchor: .topLeading)
                    .offset(pan)

                // Plain drag pans the viewport. No marquee / selection in
                // Simulate — the canvas is read-only — so any drag is a pan.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(panGesture)

                KeyEventCatcher(
                    handlers: [:],
                    commandHandlers: [
                        KeyCodes.equals: { zoomBy(1.25, anchor: anchorPoint(in: geo.size)) },
                        KeyCodes.minus:  { zoomBy(1 / 1.25, anchor: anchorPoint(in: geo.size)) },
                        KeyCodes.zero:   { applyFit(in: geo.size) },
                    ]
                )

                ScrollEventCatcher(
                    onPan: { dx, dy in
                        pan = CGSize(width: pan.width + dx, height: pan.height + dy)
                        userAdjusted = true
                    },
                    onZoom: { factor, cursor in
                        zoomBy(factor, anchor: cursor)
                    }
                )
                .allowsHitTesting(true)

                ZoomToolbar(
                    zoomPercent: zoom,
                    onZoomOut: { zoomBy(1 / 1.25, anchor: anchorPoint(in: geo.size)) },
                    onFit:     { applyFit(in: geo.size) },
                    onZoomIn:  { zoomBy(1.25, anchor: anchorPoint(in: geo.size)) }
                )
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .allowsHitTesting(true)
            }
            .coordinateSpace(name: "simulate-canvas")
            .clipped()
            .contentShape(Rectangle())
            .gesture(magnifyGesture(in: geo.size))
            .onContinuousHover(coordinateSpace: .named("simulate-canvas")) { phase in
                if case .active(let p) = phase { windowCursor = p }
            }
            .onAppear {
                if !userAdjusted { applyFit(in: geo.size) }
            }
            .onChange(of: geo.size) { _, new in
                if !userAdjusted { applyFit(in: new) }
            }
        }
    }

    // MARK: - Fit

    private func applyFit(in viewSize: CGSize) {
        let (z, p) = fit(viewSize)
        zoom = z
        pan = p
        userAdjusted = false
    }

    private func anchorPoint(in viewSize: CGSize) -> CGPoint {
        windowCursor == .zero
            ? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
            : windowCursor
    }

    // MARK: - Zoom math

    /// Zoom about an anchor in viewport coords so the content point under
    /// the anchor stays put. Same formula the editing canvases use, kept
    /// local so callers don't need to dup the math.
    private func zoomBy(_ factor: Double, anchor: CGPoint) {
        let minZoom = 0.1, maxZoom = 10.0
        let next = max(minZoom, min(maxZoom, zoom * factor))
        let f = next / zoom
        guard abs(f - 1) > 0.0001 else { return }
        pan = CGSize(
            width: Double(anchor.x) - (Double(anchor.x) - pan.width) * f,
            height: Double(anchor.y) - (Double(anchor.y) - pan.height) * f
        )
        zoom = next
        userAdjusted = true
    }

    // MARK: - Gestures

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                if bgDragMode == .none {
                    bgDragMode = .pan
                    panBaseline = pan
                }
                // value.translation is in the local (scaled) coord system,
                // multiply by zoom to keep cursor-following 1:1.
                pan = CGSize(
                    width: panBaseline.width + value.translation.width * zoom,
                    height: panBaseline.height + value.translation.height * zoom
                )
                userAdjusted = true
            }
            .onEnded { _ in bgDragMode = .none }
    }

    private func magnifyGesture(in viewSize: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if magnifyBaseline == nil { magnifyBaseline = (zoom, pan) }
                guard let base = magnifyBaseline else { return }
                let anchor = anchorPoint(in: viewSize)
                let raw = max(0.05, value.magnification)
                let next = max(0.1, min(10.0, base.zoom * raw))
                let f = next / base.zoom
                pan = CGSize(
                    width: Double(anchor.x) - (Double(anchor.x) - base.pan.width) * f,
                    height: Double(anchor.y) - (Double(anchor.y) - base.pan.height) * f
                )
                zoom = next
                userAdjusted = true
            }
            .onEnded { _ in magnifyBaseline = nil }
    }
}
