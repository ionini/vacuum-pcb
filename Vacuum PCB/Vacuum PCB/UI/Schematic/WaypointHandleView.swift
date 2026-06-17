import SwiftUI

/// A draggable handle for one wire waypoint. Lives in the scaled schematic
/// subtree (so its coordinates are schematic units) above the net lines.
/// Dragging reports the new schematic point live (the wire bends as you drag)
/// and again on release (where the canvas snaps it to the grid). Right-clicking
/// a handle removes it — handled by the canvas's right-click catcher, not here.
struct WaypointHandleView: View {
    let point: CGPoint
    var onChanged: (CGPoint) -> Void
    var onEnded: (CGPoint) -> Void

    @Environment(\.schematicZoom) private var zoom: Double
    @Environment(\.canvasLocked) private var locked: Bool
    @State private var startPoint: CGPoint?

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1))
            .frame(width: 9, height: 9)
            // Generous invisible hit target so the small dot is easy to grab.
            .background(Circle().fill(Color.white.opacity(0.001)).frame(width: 22, height: 22))
            .position(point)
            .gesture(drag, including: locked ? .none : .gesture)
            .help("Drag to route · right-click to remove")
    }

    private var drag: some Gesture {
        // `.global` so the translation is in screen pixels; divide by zoom to
        // get schematic units. `startPoint` is captured on the first tick so
        // live model updates don't compound with the gesture translation.
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let s = max(0.01, zoom)
                let start = startPoint ?? point
                if startPoint == nil { startPoint = point }
                onChanged(CGPoint(x: start.x + value.translation.width / s,
                                  y: start.y + value.translation.height / s))
            }
            .onEnded { value in
                let s = max(0.01, zoom)
                let start = startPoint ?? point
                startPoint = nil
                onEnded(CGPoint(x: start.x + value.translation.width / s,
                                y: start.y + value.translation.height / s))
            }
    }
}
