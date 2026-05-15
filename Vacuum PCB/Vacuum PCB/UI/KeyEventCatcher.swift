import SwiftUI
import AppKit

/// Window-level keyboard handler that doesn't depend on SwiftUI focus.
///
/// SwiftUI's `keyboardShortcut(...)` on a hidden Button looks reliable but
/// silently breaks when focus shifts away (a TextField in the inspector
/// becomes first responder, a child view eats focus on tap, etc.). This view
/// registers an `NSEvent.addLocalMonitorForEvents` while it's attached to a
/// window and consumes matching key presses regardless of focus — except
/// when a text field is the first responder, in which case the event passes
/// through so typing into the field still works.
///
/// Drop it into a ZStack with `.allowsHitTesting(true)` somewhere; it returns
/// nil from `hitTest` so it never blocks left-clicks.
struct KeyEventCatcher: NSViewRepresentable {
    /// Callback for each key code we care about. Keys are AppKit virtual key
    /// codes (e.g. 51 for delete, 117 for forward-delete, 53 for escape).
    let handlers: [UInt16: () -> Void]

    func makeNSView(context: Context) -> KeyEventCatcherView {
        let v = KeyEventCatcherView()
        v.handlers = handlers
        return v
    }

    func updateNSView(_ nsView: KeyEventCatcherView, context: Context) {
        nsView.handlers = handlers
    }
}

final class KeyEventCatcherView: NSView {
    var handlers: [UInt16: () -> Void] = [:]
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            return
        }
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let win = self.window,
                  event.window === win
            else { return event }
            // Let text editing consume keys; otherwise the inline rename
            // TextField would lose Delete to our component-delete handler.
            if let responder = win.firstResponder,
               responder is NSText || responder is NSTextView {
                return event
            }
            if let handler = self.handlers[event.keyCode] {
                handler()
                return nil
            }
            return event
        }
    }

    deinit {
        if let m = monitor { NSEvent.removeMonitor(m) }
    }
}

/// Common AppKit virtual key codes used by this app.
enum KeyCodes {
    static let delete: UInt16        = 51
    static let forwardDelete: UInt16 = 117
    static let escape: UInt16        = 53
    static let r: UInt16             = 15
    static let f: UInt16             = 3
    static let v: UInt16             = 9
}
