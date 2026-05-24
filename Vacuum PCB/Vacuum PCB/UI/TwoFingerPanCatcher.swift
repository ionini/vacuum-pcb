import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Two-finger pan for the canvas views on iPad. SwiftUI's `DragGesture`
/// doesn't surface finger count, so this drops a UIKit
/// `UIPanGestureRecognizer` configured with `min/maxNumberOfTouches = 2`
/// onto the host window — same window-level pattern `ScrollEventCatcher`
/// and `RightClickCatcher` use on macOS via `NSEvent.addLocalMonitor` —
/// and scopes it to the catcher's frame so other canvases on the same
/// window don't pan simultaneously.
///
/// macOS already pans via the trackpad / scroll wheel through
/// `ScrollEventCatcher` and via Option-drag, so on AppKit this view is a
/// no-op. The catcher does not consume single-touch events: marquee,
/// component drag, pin tap, and drag-to-route all keep working from one
/// finger.
struct TwoFingerPanCatcher: View {
    let onPan: (CGFloat, CGFloat) -> Void

    var body: some View {
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        TwoFingerPanCatcherRepresentable(onPan: onPan)
        #else
        Color.clear.allowsHitTesting(false)
        #endif
    }
}

#if canImport(UIKit) && !targetEnvironment(macCatalyst)

private struct TwoFingerPanCatcherRepresentable: UIViewRepresentable {
    let onPan: (CGFloat, CGFloat) -> Void

    func makeUIView(context: Context) -> TwoFingerPanCatcherView {
        let v = TwoFingerPanCatcherView()
        v.onPan = onPan
        return v
    }

    func updateUIView(_ uiView: TwoFingerPanCatcherView, context: Context) {
        uiView.onPan = onPan
    }
}

final class TwoFingerPanCatcherView: UIView, UIGestureRecognizerDelegate {
    var onPan: ((CGFloat, CGFloat) -> Void)?
    private let panRecognizer = UIPanGestureRecognizer()
    private weak var installedWindow: UIWindow?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        panRecognizer.minimumNumberOfTouches = 2
        panRecognizer.maximumNumberOfTouches = 2
        panRecognizer.addTarget(self, action: #selector(handlePan(_:)))
        panRecognizer.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Don't intercept any hit tests — sibling SwiftUI gestures (marquee,
    /// pin drag, component drag, the floating zoom toolbar) should all
    /// keep receiving touches. The recognizer runs on the window so it
    /// still sees two-finger pans without needing the catcher in the
    /// touch path.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let installedWindow {
            installedWindow.removeGestureRecognizer(panRecognizer)
        }
        installedWindow = window
        window?.addGestureRecognizer(panRecognizer)
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let window else { return }
        let t = recognizer.translation(in: window)
        // Emit deltas (not cumulative) so callers can compose onto their
        // existing transform without subtracting a baseline.
        recognizer.setTranslation(.zero, in: window)
        onPan?(t.x, t.y)
    }

    // MARK: - UIGestureRecognizerDelegate

    /// Coexist with SwiftUI's `MagnifyGesture` (also two-finger) so the
    /// user can pinch-zoom and pan at the same time.
    func gestureRecognizer(
        _ a: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer
    ) -> Bool { true }

    /// Only let the recognizer fire when both fingers are inside this
    /// catcher's frame, so a different canvas on the same window (or
    /// the parking-lot / inspector area) doesn't get phantom pans.
    /// UIView declares its own `gestureRecognizerShouldBegin`, so the
    /// `override` keyword is required even though we're only
    /// participating in the recognizer's delegate protocol here.
    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let window, recognizer.numberOfTouches == 2 else { return false }
        let frameInWindow = window.convert(bounds, from: self)
        for i in 0..<recognizer.numberOfTouches {
            let p = recognizer.location(ofTouch: i, in: window)
            if !frameInWindow.contains(p) { return false }
        }
        return true
    }
}

#endif
