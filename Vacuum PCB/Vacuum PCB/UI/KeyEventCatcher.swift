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
    /// Callbacks for each key code we care about, fired when *no* modifier
    /// is held (Shift is currently ignored). Keys are AppKit virtual key
    /// codes (e.g. 51 for delete, 117 for forward-delete, 53 for escape).
    let handlers: [UInt16: () -> Void]
    /// Callbacks for ⌘+keyCode bindings — separated from the plain map so
    /// `0` (drop via on a physical canvas) doesn't collide with `⌘0` (fit
    /// to view). Cmd-only; Cmd+Shift or Cmd+Option pass through.
    let commandHandlers: [UInt16: () -> Void]

    init(handlers: [UInt16: () -> Void], commandHandlers: [UInt16: () -> Void] = [:]) {
        self.handlers = handlers
        self.commandHandlers = commandHandlers
    }

    func makeNSView(context: Context) -> KeyEventCatcherView {
        let v = KeyEventCatcherView()
        v.handlers = handlers
        v.commandHandlers = commandHandlers
        return v
    }

    func updateNSView(_ nsView: KeyEventCatcherView, context: Context) {
        nsView.handlers = handlers
        nsView.commandHandlers = commandHandlers
    }
}

final class KeyEventCatcherView: NSView {
    var handlers: [UInt16: () -> Void] = [:]
    var commandHandlers: [UInt16: () -> Void] = [:]
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
            // Split routing by the Command modifier. Cmd+key only fires
            // commandHandlers; plain (no modifier) only fires handlers.
            // Anything else (Option, Shift+Control, etc.) passes through.
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isCmdOnly = flags == .command
            let isPlain   = flags.subtracting([.shift, .capsLock, .function, .numericPad]).isEmpty
            if isCmdOnly, let handler = self.commandHandlers[event.keyCode] {
                handler()
                return nil
            }
            if isPlain, let handler = self.handlers[event.keyCode] {
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
    /// = / + key (US layout). Bound to ⌘= for zoom-in; SwiftUI canonicalises
    /// the "+" form to "=" so the same physical key works without Shift.
    static let equals: UInt16        = 24
    static let minus: UInt16         = 27
    /// Top-row 0 — also `KeyCodes.digit[0]`. Aliased so the zoom code reads
    /// cleanly without leaking the digit-array convention.
    static let zero: UInt16          = 29

    /// Top-row number keys (not the numpad). Index by digit 0…9.
    static let digit: [UInt16] = [
        29, // 0
        18, // 1
        19, // 2
        20, // 3
        21, // 4
        23, // 5
        22, // 6
        26, // 7
        28, // 8
        25  // 9
    ]
}
