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
    /// Fires the instant a second finger touches down — before the pan
    /// recognizer's movement threshold has been crossed. Canvases use it
    /// to abort any single-finger drag that started a few ms earlier so
    /// the user can pan/pinch without dragging the component their first
    /// finger happens to be over.
    var onMultiTouchBegan: () -> Void = {}

    var body: some View {
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        // Frame the wrapper so SwiftUI lays out a real, full-canvas view.
        // The recognizer is attached at window level, so the size doesn't
        // gate recognition — but a zero-sized view did hide a separate
        // bounds filter that we've since removed, and the explicit frame
        // also keeps the diagnostics tooling (Reveal etc.) from claiming
        // the catcher "isn't there".
        TwoFingerPanCatcherRepresentable(onPan: onPan, onMultiTouchBegan: onMultiTouchBegan)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        #else
        Color.clear.allowsHitTesting(false)
        #endif
    }
}

#if canImport(UIKit) && !targetEnvironment(macCatalyst)

private struct TwoFingerPanCatcherRepresentable: UIViewRepresentable {
    let onPan: (CGFloat, CGFloat) -> Void
    let onMultiTouchBegan: () -> Void

    func makeUIView(context: Context) -> TwoFingerPanCatcherView {
        let v = TwoFingerPanCatcherView()
        v.onPan = onPan
        v.onMultiTouchBegan = onMultiTouchBegan
        return v
    }

    func updateUIView(_ uiView: TwoFingerPanCatcherView, context: Context) {
        uiView.onPan = onPan
        uiView.onMultiTouchBegan = onMultiTouchBegan
    }
}

final class TwoFingerPanCatcherView: UIView, UIGestureRecognizerDelegate {
    var onPan: ((CGFloat, CGFloat) -> Void)?
    var onMultiTouchBegan: (() -> Void)?
    private let panRecognizer = UIPanGestureRecognizer()
    /// Fires the moment two fingers are down (zero-duration long press,
    /// two touches required), *before* the pan recognizer's movement
    /// threshold has been crossed. The pan recognizer alone wouldn't be
    /// enough: by the time it transitions to .began, SwiftUI's
    /// DragGesture on a component the first finger landed on has already
    /// committed to a drag. This detector races ahead and signals the
    /// canvas to abort that drag.
    private let multiTouchDetector = UILongPressGestureRecognizer()
    private weak var installedWindow: UIWindow?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        panRecognizer.minimumNumberOfTouches = 2
        panRecognizer.maximumNumberOfTouches = 2
        panRecognizer.addTarget(self, action: #selector(handlePan(_:)))
        panRecognizer.delegate = self

        multiTouchDetector.minimumPressDuration = 0
        multiTouchDetector.numberOfTouchesRequired = 2
        // Don't disrupt the SwiftUI gestures we coexist with — we only
        // need the .began signal; the in-flight touches must keep flowing
        // to the pan recognizer and MagnifyGesture.
        multiTouchDetector.cancelsTouchesInView = false
        multiTouchDetector.delaysTouchesBegan = false
        multiTouchDetector.delaysTouchesEnded = false
        multiTouchDetector.addTarget(self, action: #selector(handleMultiTouchDetect(_:)))
        multiTouchDetector.delegate = self
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
            installedWindow.removeGestureRecognizer(multiTouchDetector)
        }
        installedWindow = window
        window?.addGestureRecognizer(panRecognizer)
        window?.addGestureRecognizer(multiTouchDetector)
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let window else { return }
        let t = recognizer.translation(in: window)
        // Emit deltas (not cumulative) so callers can compose onto their
        // existing transform without subtracting a baseline.
        recognizer.setTranslation(.zero, in: window)
        onPan?(t.x, t.y)
    }

    @objc private func handleMultiTouchDetect(_ recognizer: UILongPressGestureRecognizer) {
        if recognizer.state == .began {
            onMultiTouchBegan?()
        }
    }

    // MARK: - UIGestureRecognizerDelegate

    /// Coexist with SwiftUI's `MagnifyGesture` (also two-finger) so the
    /// user can pinch-zoom and pan at the same time.
    func gestureRecognizer(
        _ a: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer
    ) -> Bool { true }

    /// Require two active touches. We deliberately do *not* gate on the
    /// catcher's view frame: the canvas tab switching means only one
    /// catcher is mounted per document window at a time, and the
    /// recognizer is installed window-level so the host view's bounds
    /// don't influence what touches reach it. Earlier attempts to scope
    /// to `bounds` fired never on real iPads because SwiftUI hadn't
    /// given the wrapper a non-zero frame yet.
    /// UIView declares its own `gestureRecognizerShouldBegin`, so the
    /// `override` keyword is required even though we're only
    /// participating in the recognizer's delegate protocol here.
    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        true
    }
}

#endif
