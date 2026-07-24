import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Reports whether the hosting window is actually visible on screen, via
/// `NSWindow.occlusionState`.
///
/// Exists because macOS *window* tabs don't unmount their content the way
/// DocumentView's in-window tab switch does: a deselected window tab keeps
/// its whole view hierarchy (timers included) alive, so `onAppear` /
/// `onDisappear` never fire and can't be used to react to the switch.
/// Occlusion is deliberately the signal — not key-window status — so merely
/// activating another app doesn't count as hidden while the window is still
/// on screen.
///
/// On iOS this is a no-op: the iPad build is single-document-visible and the
/// scene lifecycle already covers backgrounding.
struct WindowVisibilityCatcher: View {
    let onChange: (Bool) -> Void

    var body: some View {
        #if canImport(AppKit)
        WindowVisibilityRepresentable(onChange: onChange)
        #else
        Color.clear.allowsHitTesting(false)
        #endif
    }
}

#if canImport(AppKit)

private struct WindowVisibilityRepresentable: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> WindowVisibilityView {
        let v = WindowVisibilityView()
        v.onChange = onChange
        return v
    }

    func updateNSView(_ nsView: WindowVisibilityView, context: Context) {
        nsView.onChange = onChange
    }
}

final class WindowVisibilityView: NSView {
    var onChange: ((Bool) -> Void)?
    private var observer: NSObjectProtocol?
    /// Occlusion notifications also fire for transitions we don't care about
    /// (e.g. display sleep toggling other occlusion bits); only report actual
    /// visible/hidden flips.
    private var lastVisible: Bool?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        lastVisible = nil
        guard let win = window else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: win,
            queue: .main
        ) { [weak self] note in
            guard let self, let win = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                self.report(win.occlusionState.contains(.visible))
            }
        }
        // Seed from the current state so mounting into an already-hidden
        // window (e.g. tab restore at launch) reports hidden immediately.
        report(win.occlusionState.contains(.visible))
    }

    private func report(_ visible: Bool) {
        guard visible != lastVisible else { return }
        let isFirst = lastVisible == nil
        lastVisible = visible
        // Don't fire for the initial "it's visible" — callers only care
        // about changes, and the common mount path is a visible window.
        if isFirst && visible { return }
        onChange?(visible)
    }

    deinit {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
    }
}

#endif
