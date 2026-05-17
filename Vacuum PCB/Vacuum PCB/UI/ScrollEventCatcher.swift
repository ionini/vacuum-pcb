import SwiftUI
import AppKit

/// Window-level scroll-wheel monitor that forwards canvas-relevant events
/// (deltaX, deltaY, and whether Cmd is held) to the SwiftUI side. Used by
/// both canvases to wire the macOS-canonical pan + zoom interactions:
/// two-finger scroll / mouse wheel → pan, ⌘+scroll → zoom.
///
/// Why an NSView wrapper: SwiftUI doesn't surface scrollWheel events
/// natively. We field them with a local NSEvent monitor (same pattern as
/// `KeyEventCatcher` / `RightClickCatcher`) and report only events whose
/// cursor lies inside this view's frame, so each canvas's monitor only
/// reacts to scrolls over its own area.
struct ScrollEventCatcher: NSViewRepresentable {
    /// Pan callback: deltaX, deltaY in screen points. Positive deltaY means
    /// "user scrolled up" (content should appear to move down → pan offset
    /// grows). Trackpad and Magic Mouse both emit smooth deltas; classic
    /// wheel mice emit chunky integer steps which feel fine here.
    let onPan: (CGFloat, CGFloat) -> Void
    /// Zoom callback: a multiplicative factor (close to 1.0 per tick) and
    /// the cursor location at the moment the event fired (in the view's
    /// own coord space, top-left origin). Anchor zoom about that point.
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

    /// Don't block clicks — the canvas's interactive layers sit underneath
    /// in the SwiftUI ZStack and need to receive mouse events normally.
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

            // Convert the window-space cursor into this view's local coords
            // and gate on it — multiple ScrollEventCatchers in the same
            // window (schematic tab + physical tab, kept alive by
            // SwiftUI's view caching) would otherwise each react to every
            // scroll regardless of which canvas the mouse is over.
            let local = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(local) else { return event }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // AppKit reports Y from the bottom of the view; flip so positive
            // means "cursor screen-Y" for the canvas's top-down coord
            // system used by the rest of the SwiftUI hierarchy.
            let flippedY = self.bounds.height - local.y
            let cursorInTopDown = CGPoint(x: local.x, y: flippedY)

            // Trackpad / Magic Mouse send smooth sub-pixel deltas
            // (`hasPreciseScrollingDeltas == true`). Classic wheel mice
                // send chunky integer ticks (typically ±1 per detent), which
            // would otherwise feel painfully slow against trackpad-tuned
            // gains. Scale up non-precise events to roughly match the
            // travel users get from a single Safari scroll-page action.
            let isPrecise = event.hasPreciseScrollingDeltas
            let gain: CGFloat = isPrecise ? 1.0 : 24.0

            if flags.contains(.command) {
                // Cmd+scroll → zoom. scrollingDeltaY is the smoother of
                // the two delta channels on trackpads; we convert it to a
                // multiplicative factor near 1.0. Cap per-event factor to
                // avoid runaway zoom on a single fast flick. Mouse wheels
                // emit large discrete deltas, so we use a smaller per-unit
                // exponent for them and let the count of detents do the
                // work.
                let raw = Double(event.scrollingDeltaY)
                let perUnit = isPrecise ? 0.01 : 0.06
                let factor = max(0.5, min(2.0, exp(raw * perUnit)))
                self.onZoom?(factor, cursorInTopDown)
            } else {
                // Plain scroll → pan in screen points. Trackpad reports
                // positive deltaY for "up" gestures; we keep the natural-
                // scroll convention so the content appears to follow the
                // fingers (drag-to-scroll-content feel).
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
