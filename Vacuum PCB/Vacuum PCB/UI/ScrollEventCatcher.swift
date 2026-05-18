import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Forwards canvas-relevant scroll-wheel events (deltaX, deltaY, Cmd-held)
/// to the SwiftUI side. macOS-only: SwiftUI exposes no scroll event there,
/// so we field them with a local NSEvent monitor (same pattern as
/// `KeyEventCatcher` / `RightClickCatcher`). On iOS this is a no-op —
/// pan and zoom on iPad come from `MagnifyGesture` + `DragGesture` only.
struct ScrollEventCatcher: View {
    let onPan: (CGFloat, CGFloat) -> Void
    let onZoom: (Double, CGPoint) -> Void

    var body: some View {
        #if canImport(AppKit)
        ScrollEventCatcherRepresentable(onPan: onPan, onZoom: onZoom)
        #else
        Color.clear.allowsHitTesting(false)
        #endif
    }
}

#if canImport(AppKit)

private struct ScrollEventCatcherRepresentable: NSViewRepresentable {
    let onPan: (CGFloat, CGFloat) -> Void
    let onZoom: (Double, CGPoint) -> Void

    func makeNSView(context: Context) -> ScrollEventCatcherView {
        let v = ScrollEventCatcherView()
        v.onPan = onPan
        v.onZoom = onZoom
        return v
    }

    func updateNSView(_ nsView: ScrollEventCatcherView, context: Context) {
        nsView.onPan = onPan
        nsView.onZoom = onZoom
    }
}

final class ScrollEventCatcherView: NSView {
    var onPan: ((CGFloat, CGFloat) -> Void)?
    var onZoom: ((Double, CGPoint) -> Void)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            return
        }
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  let win = self.window,
                  event.window === win
            else { return event }

            let local = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(local) else { return event }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let flippedY = self.bounds.height - local.y
            let cursorInTopDown = CGPoint(x: local.x, y: flippedY)

            let isPrecise = event.hasPreciseScrollingDeltas
            let gain: CGFloat = isPrecise ? 1.0 : 24.0

            if flags.contains(.command) {
                let raw = Double(event.scrollingDeltaY)
                let perUnit = isPrecise ? 0.01 : 0.06
                let factor = max(0.5, min(2.0, exp(raw * perUnit)))
                self.onZoom?(factor, cursorInTopDown)
            } else {
                self.onPan?(
                    event.scrollingDeltaX * gain,
                    event.scrollingDeltaY * gain
                )
            }
            return nil
        }
    }

    deinit {
        if let m = monitor { NSEvent.removeMonitor(m) }
    }
}

#endif
